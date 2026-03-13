/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace RunAtCli.Broker.UnixNative

@[extern "lean_runat_unix_listen"]
opaque listen (path : @& String) : IO UInt32

@[extern "lean_runat_unix_accept"]
opaque accept (serverFd : UInt32) : IO UInt32

@[extern "lean_runat_unix_connect"]
opaque connect (path : @& String) : IO UInt32

@[extern "lean_runat_unix_close"]
opaque close (fd : UInt32) : IO Unit

@[extern "lean_runat_unix_send_msg"]
opaque sendMsg (fd : UInt32) (msg : @& String) : IO Unit

@[extern "lean_runat_unix_recv_msg"]
opaque recvMsg (fd : UInt32) : IO String

end RunAtCli.Broker.UnixNative
