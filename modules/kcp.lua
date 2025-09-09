--[[
MIT License

Copyright (c) 2025 Onran

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

local env = getfenv(1)

local ikcp = require "ikcp"

for k, v in pairs(ikcp) do
    env[k] = v
end

setfenv(1, env)

local function uptimeMs()
    return math.floor(time.uptime() * 1000)
end

ikcp_allocator(Bytearray)

luaikcp_pack(
    function(bits, value)
        return byteutil.pack('!'..(bits == 16 and 'H' or 'I'), value)
    end,

    function(bits, bytes)
        return byteutil.unpack('!'..(bits == 16 and 'H' or 'I'), bytes)
    end
)

local nextId = 1

local kcp = { }

local instances = { }

local function newConv()
    return math.random(0, 0xFFFFFFFF)
end

local KcpSocket = {__index={
    send=function(self, data)
        if not instances[self.id] then return end

        local type = type(data)

        if type == "string" then
            ikcp_send(self.inst, utf8.tobytes(data))
        elseif type == "table" then
            local buffer = Bytearray(#data)

            buffer:append(data)

            ikcp_send(self.inst, buffer)
        else
            ikcp_send(self.inst, data)
        end
    end,
    recv=function(self, len, useTable)
        if not instances[self.id] then return end

        local peeksize = ikcp_peeksize(self.inst)

        if len > peeksize then len = peeksize end

        if len > 0 then
            local buffer = not useTable and Bytearray(len) or { }

            ikcp_recv(self.inst, buffer, len)

            return buffer
        else return Bytearray() end
    end,
    available=function(self, len, useTable)
        if not instances[self.id] then return -1 end

        return math.max(0, ikcp_peeksize(self.inst))
    end,
    close=function(self)
        ikcp_release(self.inst)
        instances[self.id] = nil
        self.socket:close()
    end,
    set_mtu=function(self, mtu)
        ikcp_setmtu(self.inst, mtu)
    end,
    set_window_size=function(self, send, recv)
        ikcp_wndsize(self.inst, send, recv)
    end,
    get_mtu=function(self)
        return self.inst.mtu
    end,
    get_window_size=function(self)
        return self.inst.snd_wnd, self.inst.rcv_wnd
    end,
    unconfirmed_segments=function(self)
        return ikcp_waitsnd(self.inst)
    end,
    set_nodelay=function(self, nodelay)
        ikcp_nodelay(self.inst, nodelay and 1 or 0, self.inst.interval, self.inst.fastresend, self.inst.nocwnd)
    end,
    set_interval=function(self, interval)
        ikcp_nodelay(self.inst, self.inst.nodelay, interval, self.inst.fastresend, self.inst.nocwnd)
    end,
    set_resend=function(self, resend)
        ikcp_nodelay(self.inst, self.inst.nodelay, self.inst.interval, resend or 0, self.inst.nocwnd)
    end,
    set_congestion_control=function(self, nocwnd)
        ikcp_nodelay(self.inst, self.inst.nodelay, self.inst.interval, self.inst.fastresend, nocwnd and 0 or 1)
    end,
    get_nodelay=function(self)
        return self.inst.nodelay == 1
    end,
    get_interval=function(self)
        return self.inst.interval
    end,
    get_resend=function(self)
        return self.inst.fastresend
    end,
    is_congestion_control_enabled=function(self)
        return self.inst.nocwnd == 0
    end,
    is_open=function(self) return instances[self.id] ~= nil end,
    get_address=function(self) return self.socket:get_address() end,
}}

local KcpClientSocket = { __index = {
    close=function(self)
        ikcp_release(self.inst)
        instances[self.id] = nil
        self.sockets[self.address..':'..self.port]=nil
    end,
    get_address=function(self) return self.address, self.port end
}}

setmetatable(KcpClientSocket.__index, { __index = KcpSocket.__index })

local KcpServerSocket = {__index={
    close=function(self)
        if self.sockets then
            for _, socket in pairs(self.sockets) do
                socket:close()
            end
        end

        self.socket:close()
    end,
    is_open=function(self) return self.socket:is_open() end,
    get_port=function(self) return self.socket:get_port() end,
}}

function kcp.connect(address, port)
    local id = nextId

    nextId = nextId + 1

    local inst = ikcp_create(newConv())

    local socket

    local res, err = pcall(function()
        socket = network.udp_connect(
            address, port,
            function(data)
                ikcp_input(inst, data)
            end
        )
    end)

    if err then
        print("failed to open kcp connection: "..err)
        ikcp_release(inst)
        return
    end

    ikcp_setoutput(
        inst,
        function(data, size)
            local subdata

            if #data == size then subdata = data
            else
                subdata = Bytearray(size)

                for i = 1, size do
                    subdata[i] = data[i]
                end
            end

            socket:send(subdata)
        end
    )

    instances[id] = inst

    local socket = setmetatable({inst=inst, id=id, socket=socket}, KcpSocket)

    socket:set_interval(kcp.interval)

    return socket
end

function kcp.open(port, handler)
    local sockets = { }

    local socket = network.udp_open(
        port,
        function(address, port, data, server)
            local fullAddress = address..':'..port
            local handlerCallback

            if not sockets[fullAddress] then
                local inst = ikcp_create(ikcp_getconv(data))

                ikcp_setoutput(
                    inst,
                    function(data, size)
                        local subdata

                        if #data == size then subdata = data
                        else
                            subdata = Bytearray(size)

                            for i = 1, size do
                                subdata[i] = data[i]
                            end
                        end

                        server:send(address, port, subdata)
                    end
                )

                local id = nextId

                nextId = nextId + 1

                instances[id] = inst

                local kcpSocket = setmetatable({inst=inst, id=id, address=address, port=port, sockets=sockets}, KcpClientSocket)

                kcpSocket:set_interval(kcp.interval)

                sockets[fullAddress] = kcpSocket

                handlerCallback = true
            end

            ikcp_input(sockets[fullAddress].inst, data)

            if handlerCallback then
                handler(sockets[fullAddress])
            end
        end
    )

    return setmetatable({socket=socket, sockets=sockets}, KcpServerSocket)
end

function kcp.update()
    for _, instance in pairs(instances) do
        ikcp_update(instance, uptimeMs())
    end
end

function kcp.set_auto_update(autoupdate)
    kcp.autoupdate = autoupdate or false
end

function kcp.set_interval(interval)
    kcp.interval = interval or 50
end

kcp.__tick = kcp.update

kcp.autoupdate = true

kcp.interval = 50

return kcp