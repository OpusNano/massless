use std::io::Result as IoResult;
use std::io::{Error as IoError, ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::connection::Connection;
#[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
use crate::ssl::SslStream;

pub(crate) enum Stream {
    Http(Connection),
    #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
    Https(SslStream),
}

impl Stream {
    // Patched: was `Clone` with `try_clone().unwrap()`, which panicked when
    // out of file descriptors.
    fn try_clone(&self) -> IoResult<Self> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.try_clone().map(Stream::Http),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => Ok(Stream::Https(ssl_stream.clone())),
        }
    }
}

/// Patched: a read deadline shared by a connection's read half and its
/// `ClientConnection`. Once it has passed, reads fail like a socket timeout,
/// so a client that sends a request slowly (byte by byte, each within the
/// socket timeout) still can't hold the connection open.
#[derive(Clone, Default)]
pub(crate) struct Deadline(Arc<Mutex<Option<Instant>>>);

impl Deadline {
    pub(crate) fn set(&self, at: Option<Instant>) {
        if let Ok(mut d) = self.0.lock() {
            *d = at;
        }
    }

    fn passed(&self) -> bool {
        matches!(self.0.lock().map(|d| *d), Ok(Some(at)) if Instant::now() >= at)
    }
}

impl From<Connection> for Stream {
    fn from(tcp_stream: Connection) -> Self {
        Stream::Http(tcp_stream)
    }
}

impl Stream {
    fn secure(&self) -> bool {
        match self {
            Stream::Http(_) => false,
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(_) => true,
        }
    }

    fn peer_addr(&mut self) -> IoResult<Option<SocketAddr>> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.peer_addr(),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => ssl_stream.peer_addr(),
        }
    }

    fn shutdown(&mut self, how: Shutdown) -> IoResult<()> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.shutdown(how),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => ssl_stream.shutdown(how),
        }
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.read(buf),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => ssl_stream.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> IoResult<usize> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.write(buf),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => ssl_stream.write(buf),
        }
    }

    fn flush(&mut self) -> IoResult<()> {
        match self {
            Stream::Http(tcp_stream) => tcp_stream.flush(),
            #[cfg(any(feature = "ssl-openssl", feature = "ssl-rustls"))]
            Stream::Https(ssl_stream) => ssl_stream.flush(),
        }
    }
}

pub struct RefinedTcpStream {
    stream: Stream,
    close_read: bool,
    close_write: bool,
    deadline: Deadline,
}

impl RefinedTcpStream {
    pub(crate) fn new<S>(stream: S) -> IoResult<(RefinedTcpStream, RefinedTcpStream)>
    where
        S: Into<Stream>,
    {
        let stream: Stream = stream.into();

        let (read, write) = (stream.try_clone()?, stream);

        let read = RefinedTcpStream {
            stream: read,
            close_read: true,
            close_write: false,
            deadline: Deadline::default(),
        };

        let write = RefinedTcpStream {
            stream: write,
            close_read: false,
            close_write: true,
            deadline: Deadline::default(),
        };

        Ok((read, write))
    }

    /// Patched: the deadline checked before every read from this stream.
    pub(crate) fn deadline(&self) -> Deadline {
        self.deadline.clone()
    }

    /// Returns true if this struct wraps around a secure connection.
    #[inline]
    pub(crate) fn secure(&self) -> bool {
        self.stream.secure()
    }

    pub(crate) fn peer_addr(&mut self) -> IoResult<Option<SocketAddr>> {
        self.stream.peer_addr()
    }
}

impl Drop for RefinedTcpStream {
    fn drop(&mut self) {
        if self.close_read {
            self.stream.shutdown(Shutdown::Read).ok();
        }

        if self.close_write {
            self.stream.shutdown(Shutdown::Write).ok();
        }
    }
}

impl Read for RefinedTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if self.deadline.passed() {
            return Err(IoError::new(ErrorKind::WouldBlock, "read deadline passed"));
        }
        self.stream.read(buf)
    }
}

impl Write for RefinedTcpStream {
    fn write(&mut self, buf: &[u8]) -> IoResult<usize> {
        self.stream.write(buf)
    }

    fn flush(&mut self) -> IoResult<()> {
        self.stream.flush()
    }
}
