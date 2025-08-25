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

local kcp = { }

local nextConv = 0

local instances = { }

local KcpSocket = {__index={
    send=function(self, data)
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
        if not instances[self.conv] then return end

        local peeksize = ikcp_peeksize(self.inst)

        if len > peeksize then len = peeksize end

        local buffer = not useTable and Bytearray(len) or { }

        ikcp_recv(self.inst, buffer, len)

        return buffer
    end,
    available=function(self, len, useTable)
        if not instances[self.conv] then return -1 end

        return ikcp_peeksize(self.inst)
    end,
    close=function(self)
        ikcp_release(self.inst)
        instances[self.conv] = nil
        self.socket:close()
    end,
    is_open=function(self) return instances[self.conv] ~= nil end,
    get_address=function(self) return self.socket:get_address() end,
}}

local KcpClientSocket = {__index=KcpSocket,__newindex={
    close=function(self)
        ikcp_release(self.inst)
        instances[self.conv] = nil
        self.sockets[self.address..':'..self.port]=nil
    end,
    get_address=function(self) return self.address, self.port end
}}

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
    local inst = ikcp_create(nextConv)

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

            socket:write(subdata)
        end
    )

    instances[nextConv] = inst

    local kcpSocket = setmetatable({inst=inst, conv=nextConv, socket=socket}, KcpSocket)

    nextConv = nextConv + 1

    return kcpSocket
end

function kcp.open(port, handler)
    local sockets = { }

    network.udp_open(
        port,
        function(address, port, data, server)
            address = address..':'..port

            if not sockets[address] then
                local inst = ikcp_create(nextConv)

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

                instances[nextConv] = inst

                local kcpSocket = setmetatable({inst=inst, conv=nextConv, address=address, port=port, sockets=sockets}, KcpClientSocket)

                nextConv = nextConv + 1

                handler(kcpSocket)
            else
                ikcp_input(sockets[address].inst, data)
            end
        end
    )
end

function kcp.__tick()
    for _, instance in pairs(instances) do
        ikcp_update(instance, uptimeMs())
    end
end

return kcp