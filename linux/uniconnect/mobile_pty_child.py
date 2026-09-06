"""Adquiere el terminal controlador antes de sustituirse por el cliente PTY."""

import fcntl
import os
import signal
import sys
import termios


class MobilePTYChild:
    @staticmethod
    def main():
        try:
            argv = sys.argv[1:]
            if not argv or not os.path.isabs(argv[0]):
                raise ValueError()
            # Popen already created a fresh session, without a threaded preexec_fn.
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            os.tcsetpgrp(0, os.getpgrp())
            for number in (signal.SIGPIPE, signal.SIGINT, signal.SIGQUIT):
                signal.signal(number, signal.SIG_DFL)
            os.execve(argv[0], argv, os.environ)
        except (OSError, ValueError):
            os.write(2, b"No se pudo iniciar el cliente de terminal.\r\n")
            return 127


if __name__ == "__main__":
    sys.exit(MobilePTYChild.main())
