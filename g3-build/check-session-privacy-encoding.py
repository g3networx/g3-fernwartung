"""Reject invalid source encoding before downloading native build dependencies."""
from pathlib import Path

for name in ('src/g3_sessions.rs', 'src/server/connection.rs'):
    Path(name).read_bytes().decode('utf-8')
print('Changed native sources are valid UTF-8')
