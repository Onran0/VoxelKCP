local kcp = require "kcp"

function on_world_tick()
    if kcp.autoupdate then
        kcp.update()
    end
end