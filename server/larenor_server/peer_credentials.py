"""Read Unix peer identity from the kernel, never from a client frame."""

import socket
import struct


def unix_peer_uid(connection):
    if hasattr(connection, 'getpeereid'):
        uid = connection.getpeereid()[0]
    elif hasattr(socket, 'SO_PEERCRED'):
        uid = struct.unpack('3i', connection.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    elif hasattr(socket, 'LOCAL_PEERCRED'):
        # Darwin xucred starts with two native uint32 values: layout version
        # and effective UID. XUCRED_VERSION is 0; groups are not needed here.
        version, uid = struct.unpack('2I', connection.getsockopt(
            0, socket.LOCAL_PEERCRED, 8))
        if version != 0:
            raise OSError('peer_identity_unavailable')
    else:
        raise OSError('peer_identity_unavailable')
    if type(uid) is not int or not 0 <= uid < 2**32 - 1:
        raise OSError('peer_identity_unavailable')
    return uid
