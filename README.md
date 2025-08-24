# ![kcp2vc](icon256.png) kcp2vc

Fast pure-Lua KCP implementation for [Voxel Core](https://github.com/MihailRis/voxelcore)

Examples of usage:

```lua
local kcp = require "kcp:kcp"

local bufferSize = 1024

-- Listen
local kcpServer = kcp.open(
    7777,
    function(socket)
        print(utf8.tostring(socket:recv(bufferSize)))

        socket:write("Hello!")
    end
)

-- Connect
local kcpClient = kcp.connect(
    "127.0.0.1",
    7777
)

kcpClient:send("Hi!")
print(utf8.tostring(kcpClient:recv(bufferSize)))
```
# Documentation
[RU](docs/ru/dev.md)

# Links
Original [**kcp**](https://github.com/skywind3000/kcp) repository
