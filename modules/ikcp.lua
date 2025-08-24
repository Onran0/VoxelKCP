--[[
Line-by-line port of KCP to Lua

Source repository: https://github.com/skywind3000/kcp

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

local bit = bit or bit32

if not bit then
    local major, minor = _VERSION:match("Lua (%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)

    if major > 5 or (major == 5 and minor >= 3) then
        bit = load[[
            return {
                bor = function(a, b)
                    return a | b
                end,

                band = function(a, b)
                    return a & b
                end,

                lshift = function(a, b)
                    return a << b
                end,

				rshift = function(a, b)
					return a >> b
				end
            }
        ]]()
    else error "bit/bit32 library is not defined" end
end

local NULL = nil

local DEFAULT_MALLOC = function(capacity)
    return {
        insert = function(self, index, b)
            if type(b) == "number" then
                table.insert(self, index, b)
            else
                for i = 1, #b do
                    table.insert(self, index, b[i])
                end
            end
        end,

        clear = function(self)
            for i = 1, #self do
                self[i] = nil
            end
        end,

        remove = function(self, index, count)
            for i = 1, count do
                table.remove(self, index)
            end
        end,

        append = function(self, b)
            if type(b) == "number" then
                self[#self + 1] = b
            else
                for i = 1, #b do
                    self[#self + 1] = b[i]
                end
            end
        end
    }
end
local DEFAULT_FREE = function(data) end

local DEFAULT_PACK = function(bits, value)
    if bits == 16 then
        return {
            bit.band(value, 0x00FF),
            bit.band(value, 0xFF00)
        }
    elseif bits == 32 then
        return {
            bit.band(value, 0x000000FF),
            bit.band(value, 0x0000FF00),
            bit.band(value, 0x00FF0000),
            bit.band(value, 0xFF000000)
        }
    end
end

local DEFAULT_UNPACK = function(bits, bytes)
    if bits == 16 then
        return bit.bor(
            bytes[1],
            bit.lshift(
                bytes[2],
                8
            )
        )
    elseif bits == 32 then
        return bit.bor(
            bit.bor(
                bit.bor(
                    bytes[1],
                    bit.lshift(
                        bytes[2],
                        8
                    )
                ),
                bit.lshift(
                    bytes[3],
                    16
                )
            ),
            bit.lshift(
                bytes[4],
                24
            )
        )
    end
end

local MALLOC = DEFAULT_MALLOC
local FREE = DEFAULT_FREE

local PACK = DEFAULT_PACK
local UNPACK = DEFAULT_UNPACK

local IKCP_FASTACK_CONSERVE = false

local IKCP_LOG_OUTPUT		=   	1
local IKCP_LOG_INPUT		=   	2
local IKCP_LOG_SEND			=       4
local IKCP_LOG_RECV			=       8
local IKCP_LOG_IN_DATA		=       16
local IKCP_LOG_IN_ACK		=   	32
local IKCP_LOG_IN_PROBE		=       64
local IKCP_LOG_IN_WINS		=       128
local IKCP_LOG_OUT_DATA		=       256
local IKCP_LOG_OUT_ACK		=       512
local IKCP_LOG_OUT_PROBE	=   	1024
local IKCP_LOG_OUT_WINS     =		2048

--=====================================================================
-- KCP BASIC
--=====================================================================
local IKCP_RTO_NDL = 30		            -- no delay min rto
local IKCP_RTO_MIN = 100		        -- normal min rto
local IKCP_RTO_DEF = 200
local IKCP_RTO_MAX = 60000
local IKCP_CMD_PUSH = 81		        -- cmd: push data
local IKCP_CMD_ACK  = 82		        -- cmd: ack
local IKCP_CMD_WASK = 83		        -- cmd: window probe (ask)
local IKCP_CMD_WINS = 84		        -- cmd: window size (tell)
local IKCP_ASK_SEND = 1		            -- need to send IKCP_CMD_WASK
local IKCP_ASK_TELL = 2		            -- need to send IKCP_CMD_WINS
local IKCP_WND_SND = 32
local IKCP_WND_RCV = 128                -- must >= max fragment size
local IKCP_MTU_DEF = 1400
local IKCP_ACK_FAST	= 3
local IKCP_INTERVAL	= 100
local IKCP_OVERHEAD = 24
local IKCP_DEADLINK = 20
local IKCP_THRESH_INIT = 2
local IKCP_THRESH_MIN = 2
local IKCP_PROBE_INIT = 7000		    -- 7 secs to probe window size
local IKCP_PROBE_LIMIT = 120000	        -- up to 120 secs to probe window
local IKCP_FASTACK_LIMIT = 5		    -- max times to trigger fastack

local function _ibound_(lower, middle, upper) 
	return math.min(math.max(lower, middle), upper)
end

local function _itimediff(later, earlier)
	return later - earlier
end

local function iqueue_init(q)
    q.next, q.prev = q, q
end

local function iqueue_add(node, head)
    node.next = head.next
    node.prev = head
    head.next.prev = node
    head.next = node
end

local function iqueue_add_tail(node, head)
    node.prev = head.prev
    node.next = head
    head.prev.next = node
    head.prev = node
end

local function iqueue_del(node)
    node.prev.next = node.next
    node.next.prev = node.prev
    node.next = nil
    node.prev = nil
end

local function iqueue_is_empty(head)
    return head.next == head
end

local function iqueue_del_init(node)
    node.prev.next = node.next
    node.next.prev = node.prev
    node.next = node
    node.prev = node
end

local function ikcp_malloc(size)
	return MALLOC(size)
end

local function ikcp_free(data)
	FREE(data)
end

-- encode 8 bits unsigned int
local function ikcp_encode8u(data, value)
	data.append(data, value)
end

-- decode 8 bits unsigned int
local function ikcp_decode8u(data)
	local res = data[1]

    data.remove(data, 1)

    return res
end

-- encode 16 bits unsigned int (lsb)
local function ikcp_encode16u(data, value)
    data.append(data, PACK(16, value))
end

-- decode 16 bits unsigned int (lsb)
local function ikcp_decode16u(data)
    local res = UNPACK(16, { data[1], data[2] })

    data.remove(data, 1, 2)

    return res
end

-- encode 32 bits unsigned int (lsb)
local function ikcp_encode32u(data, value)
    data.append(data, PACK(32, value))
end

-- decode 32 bits unsigned int (lsb)
local function ikcp_decode32u(data)
    local res = UNPACK(32, { data[1], data[2], data[3], data[4] })

    data.remove(data, 1, 4)

    return res
end

local function get_u32(data, offset)
	offset = offset * 4

	return UNPACK(32, { data[offset + 1], data[offset + 2], data[offset + 3], data[offset + 4] })
end

local function set_u32(data, offset, value)
	offset = offset * 4

	local bytes = PACK(32, value)

	for i = 1, 4 do
		data[offset + i] = bytes[i]
	end
end

local function ikcp_segment_new(kcp, size)
    local seg = { frg = 0, data = ikcp_malloc(size), node = { } }

    seg.node.value = seg

    return seg
end

local function ikcp_segment_delete(kcp, seg)
	ikcp_free(seg.data)
end

local function ikcp_encode_seg(data, seg)
	ikcp_encode32u(ptr, seg.conv)
	ikcp_encode8u(ptr, bit.band(0xFF, seg.cmd))
	ikcp_encode8u(ptr, bit.band(0xFF, seg.frg))
	ikcp_encode16u(ptr, bit.band(0xFFFF, seg.wnd))
	ikcp_encode32u(ptr, seg.ts)
	ikcp_encode32u(ptr, seg.sn)
	ikcp_encode32u(ptr, seg.una)
	ikcp_encode32u(ptr, seg.len)
end

local function ikcp_canlog(kcp, mask)
	return bit.band(mask, kcp.logmask) ~= 0 and kcp.writelog ~= NULL
end

local function ikcp_log(kcp, mask, fmt, ...)
	if bit.mask(mask, kcp.logmask) == 0 or kcp.writelog == NULL then return end
	
	kcp.writelog(string.format(fmt, ...), kcp, kcp.user)
end

local function ikcp_ack_get(kcp, p, sn, ts)
	if sn then sn = get_u32(kcp.acklist, p * 2 + 0) end
	if ts then ts = get_u32(kcp.acklist, p * 2 + 1) end

	return sn, ts
end

-----------------------------------------------------------------------
-- ack append
-----------------------------------------------------------------------
local function ikcp_ack_push(kcp, sn, ts)
	local newsize = kcp.ackcount + 1

	if newsize > kcp.ackblock then
		local acklist
		local newblock = 8

		repeat newblock = bit.lshift(newblock, 1) until newblock >= newsize

		acklist = ikcp_malloc(newblock * 4 * 2)

		assert(acklist ~= NULL)

		if kcp.acklist ~= NULL then
			for x = 0, kcp.ackcount - 1 do
				set_u32(acklist, x * 2 + 0, get_u32(kcp.acklist, x * 2 + 0))
				set_u32(acklist, x * 2 + 1, get_u32(kcp.acklist, x * 2 + 1))
			end

			ikcp_free(kcp.acklist)
		end

		kcp.acklist = acklist
		kcp.ackblock = newblock
	end

	local index = kcp.ackcount * 2

	set_u32(kcp.acklist, index, sn)
	set_u32(kcp.acklist, index + 1, ts)

	kcp.ackcount = kcp.ackcount + 1
end

local function ikcp_shrink_buf(kcp)
	local p = kcp.snd_buf.next
	if p ~= kcp.snd_buf then
		kcp.snd_una = p.value.sn
	else
		kcp.snd_una = kcp.snd_nxt
	end
end

local function ikcp_parse_ack(kcp, sn)
	local p, next

	if _itimediff(sn, kcp.snd_una) < 0 or _itimediff(sn, kcp.snd_nxt) >= 0 then return end

	p = kcp.snd_buf.next

	repeat
		local seg = p.value

		next = p.next

		if sn == seg.sn then
			iqueue_del(p)
			ikcp_segment_delete(kcp, seg)
			kcp.nsnd_buf = kcp.nsnd_buf - 1
			break;
		end
		if _itimediff(sn, seg.sn) < 0 then break end

		p = next
	until p == kcp.snd_buf
end

local function ikcp_update_ack(kcp, rtt)
	local rto
	if kcp.rx_srtt == 0 then
		kcp.rx_srtt = rtt
		kcp.rx_rttval = math.floor(rtt / 2)
	else
		local delta = rtt - kcp.rx_srtt
		if delta < 0 then delta = -delta end
		kcp.rx_rttval = math.floor((3 * kcp.rx_rttval + delta) / 4)
		kcp.rx_srtt = math.floor((7 * kcp.rx_srtt + rtt) / 8)
		if kcp.rx_srtt < 1 then kcp.rx_srtt = 1 end
	end
	rto = kcp.rx_srtt + math.max(kcp.interval, 4 * kcp.rx_rttval)
	kcp.rx_rto = _ibound_(kcp.rx_minrto, rto, IKCP_RTO_MAX)
end

local function ikcp_parse_una(kcp, una)
	local p, next

	p = kcp.snd_buf.next
	repeat
		local seg = p.value
		next = p.next
		if _itimediff(una, seg.sn) > 0 then
			iqueue_del(p)
			ikcp_segment_delete(kcp, seg)
			kcp.nsnd_buf = kcp.nsnd_buf - 1
		else break end

		p = next
	until p == kcp.snd_buf
end

local function ikcp_parse_fastack(kcp, sn, ts)
	local p, next

	if _itimediff(sn, kcp.snd_una) < 0 or _itimediff(sn, kcp.snd_nxt) >= 0 then return end

	p = kcp.snd_buf.next

	repeat
		local seg = p.value
		next = p.next
		if _itimediff(sn, seg.sn) < 0 then
			break
		elseif sn ~= seg.sn then
			if not IKCP_FASTACK_CONSERVE then
				seg.fastack = seg.fastack + 1
			else
				if _itimediff(ts, seg.ts) >= 0 then
					seg.fastack = seg.fastack + 1
				end
			end
		end

		p = next
	until p == kcp.snd_buf
end

local function ikcp_wnd_unused(kcp)
	if kcp.nrcv_que < kcp.rcv_wnd then
		return kcp.rcv_wnd - kcp.nrcv_que
	end
	return 0
end

local function ikcp_create(conv, user)
	local kcp = { }

	kcp.conv = conv
	kcp.user = user
	kcp.snd_una = 0
	kcp.snd_nxt = 0
	kcp.rcv_nxt = 0
	kcp.ts_recent = 0
	kcp.ts_lastack = 0
	kcp.ts_probe = 0
	kcp.probe_wait = 0
	kcp.snd_wnd = IKCP_WND_SND
	kcp.rcv_wnd = IKCP_WND_RCV
	kcp.rmt_wnd = IKCP_WND_RCV
	kcp.cwnd = 0
	kcp.incr = 0
	kcp.probe = 0
	kcp.mtu = IKCP_MTU_DEF
	kcp.mss = kcp.mtu - IKCP_OVERHEAD
	kcp.stream = 0

	kcp.buffer = ikcp_malloc((kcp.mtu + IKCP_OVERHEAD) * 3)

	kcp.snd_queue = { }
    kcp.rcv_queue = { }
    kcp.snd_buf = { }
    kcp.rcv_buf = { }

    iqueue_init(kcp.snd_queue)
    iqueue_init(kcp.rcv_queue)
    iqueue_init(kcp.snd_buf)
    iqueue_init(kcp.rcv_buf)

	kcp.nrcv_buf = 0
	kcp.nsnd_buf = 0
	kcp.nrcv_que = 0
	kcp.nsnd_que = 0
	kcp.state = 0
	kcp.acklist = NULL
	kcp.ackblock = 0
	kcp.ackcount = 0
	kcp.rx_srtt = 0
	kcp.rx_rttval = 0
	kcp.rx_rto = IKCP_RTO_DEF
	kcp.rx_minrto = IKCP_RTO_MIN
	kcp.current = 0
	kcp.interval = IKCP_INTERVAL
	kcp.ts_flush = IKCP_INTERVAL
	kcp.nodelay = 0
	kcp.updated = 0
	kcp.logmask = 0
	kcp.ssthresh = IKCP_THRESH_INIT
	kcp.fastresend = 0
	kcp.fastlimit = IKCP_FASTACK_LIMIT
	kcp.nocwnd = 0
	kcp.xmit = 0
	kcp.dead_link = IKCP_DEADLINK
	kcp.output = NULL
	kcp.writelog = NULL

	return kcp
end

local function ikcp_release(kcp)
	assert(kcp)

	local seg

	while not iqueue_is_empty(kcp.snd_buf) do
		seg = kcp.snd_buf.next.value
		iqueue_del(seg.node)
		ikcp_segment_delete(kcp, seg)
    end

    while not iqueue_is_empty(kcp.rcv_buf) do
		seg = kcp.rcv_buf.next.value
		iqueue_del(seg.node)
		ikcp_segment_delete(kcp, seg)
    end

    while not iqueue_is_empty(kcp.snd_queue) do
		seg = kcp.snd_queue.next.value
		iqueue_del(seg.node)
		ikcp_segment_delete(kcp, seg)
    end

    while not iqueue_is_empty(kcp.rcv_queue) do
		seg = kcp.rcv_queue.next.value
		iqueue_del(seg.node)
		ikcp_segment_delete(kcp, seg)
    end

	if kcp.buffer then
		ikcp_free(kcp.buffer)
    end

	if kcp.acklist then
		ikcp_free(kcp.acklist)
    end

	kcp.nrcv_buf = 0
	kcp.nsnd_buf = 0
	kcp.nrcv_que = 0
	kcp.nsnd_que = 0
	kcp.ackcount = 0
	kcp.buffer = NULL
	kcp.acklist = NULL
end

local function ikcp_setoutput(kcp, output)
    kcp.output = output
end

local function ikcp_send(kcp, buffer, len)
    local len = len or #buffer

	local seg
	local count, i
	local sent = 0

    local offset = 0

	assert(kcp.mss > 0)

	-- append to previous segment in streaming mode (if possible)
	if  kcp.stream ~= 0 then
		if not iqueue_is_empty(kcp.snd_queue) then
            
			local old = kcp.snd_queue.prev.value

			if #old.data < kcp.mss then
				local capacity = kcp.mss - #old.data
				local extend = (len < capacity) and len or capacity

                seg = ikcp_segment_new(kcp, #old.data + extend)

				iqueue_add_tail({ value = seg }, kcp.snd_queue)

                seg.data.insert(seg.data, 1, old.data)

				if buffer then
                    for i = 1, extend do
                        seg.data[#seg.data + i] = buffer[i]
                    end
					
                    offset = offset + extend
                end

				seg.len = old.len + extend
				seg.frg = 0
				len = len - extend

				iqueue_del_init(old.node)

                ikcp_segment_delete(kcp, old)

				sent = extend
			end
		end

		if len <= 0 then return sent end
	end

	if len <= kcp.mss then count = 1
	else count = math.floor((len + kcp.mss - 1) / kcp.mss) end

	if count >= IKCP_WND_RCV then
		if kcp.stream ~= 0 and sent > 0 then return sent end

		return -2;
    end

	if count == 0 then count = 1 end

	-- fragment
	for i = 1, count do
		local size = len > kcp.mss and kcp.mss or len

        seg = ikcp_segment_new(size)

		if buffer and len > 0 then
            for i = 1, size do
                seg.data[i] = buffer[i + offset]
            end
        end

		seg.len = size
		seg.frg = (kcp.stream == 0) and (count - i - 1) or 0

		iqueue_init(seg.node)
		iqueue_add_tail(seg.node, kcp.snd_queue)

		kcp.nsnd_que = kcp.nsnd_que + 1

		if buffer then
			offset = offset + size
        end

		len = len - size
		sent = sent + size
	end

	return sent
end

local function ikcp_output(kcp, data, size)
	assert(kcp)
	assert(kcp.output)

	if ikcp_canlog(kcp, IKCP_LOG_OUTPUT) then
		ikcp_log(kcp, IKCP_LOG_OUTPUT, "[RO] %d bytes", size);
    end

	if size == 0 then return 0 end

	return kcp.output(data, size, kcp, kcp.user)
end

local function ikcp_peeksize(kcp)
	local p
	local seg
	local length = 0

	assert(kcp)

	if iqueue_is_empty(kcp.rcv_queue) then return -1 end

	seg = kcp.rcv_queue.next.value

	if seg.frg == 0 then return #seg.data end

	if kcp.nrcv_que < seg.frg + 1 then return -1 end

    p = kcp.rcv_queue.next

    repeat
		seg = p.value
		length = length + #seg.data

		if seg.frg == 0 then break end

        p = p.next
    until p ~= kcp.rcv_queue

	return length;
end

local function ikcp_recv(kcp, buffer, len)
    local len = len or #buffer

	local p
	local ispeek = len < 0 and 1 or 0
	local peeksize
	local recover = 0
	local seg

    local offset = 0

	assert(kcp)

	if iqueue_is_empty(kcp.rcv_queue) then return -1 end

	peeksize = ikcp_peeksize(kcp)

	if peeksize < 0 then
		return -2
    elseif peeksize > len then
		return -3
    end

	if kcp.nrcv_que >= kcp.rcv_wnd then recover = 1 end

	-- merge fragment

    len = 0

    p = kcp.rcv_queue.next

    repeat
        local fragment

		seg = node.value
		p = p.next

		if buffer then
            for i = 1, #seg.data do
                buffer[i + offset] = seg.data[i]
            end
			
			offset = offset + #seg.data
		end

		len = len + #seg.data
		fragment = seg.frg

		if ikcp_canlog(kcp, IKCP_LOG_RECV) then
			ikcp_log(kcp, IKCP_LOG_RECV, "recv sn=%d", seg.sn)
        end

		if ispeek == 0 then
			iqueue_del(seg.node)
			ikcp_segment_delete(kcp, seg)
			kcp.nrcv_que = kcp.nrcv_que - 1
        end

		if fragment == 0 then break end
    until p == kcp.rcv_queue

	assert(len == peeksize);

	-- move available data from rcv_buf -> rcv_queue
	while not iqueue_is_empty(kcp.rcv_buf) do
		seg = kcp.rcv_buf.next.value

		if seg.sn == kcp.rcv_nxt and kcp.nrcv_que < kcp.rcv_wnd then
			iqueue_del(seg.node)
			kcp.nrcv_buf = kcp.nrcv_buf - 1
			iqueue_add_tail(seg.node, kcp.rcv_queue)
			kcp.nrcv_que = kcp.nrcv_que + 1
			kcp.rcv_nxt = kcp.rcv_nxt + 1
		else break end
	end

	-- fast recover
	if kcp.nrcv_que < kcp.rcv_wnd and recover == 1 then
		-- ready to send back IKCP_CMD_WINS in ikcp_flush
		-- tell remote my window size
		kcp.probe = bit.bor(kcp.probe, IKCP_ASK_TELL)
    end

	return len;
end

local function ikcp_input(kcp, data, len)
    local size = len or #data

	local prev_una = kcp.snd_una
	local maxack, latest_ts = 0, 0
	local flag = 0

	if ikcp_canlog(kcp, IKCP_LOG_INPUT) then
		ikcp_log(kcp, IKCP_LOG_INPUT, "[RI] %d bytes", size)
    end

	if data == NULL or size < IKCP_OVERHEAD then return -1 end

	while true do
		local ts, sn, len, una, conv
		local wnd
		local cmd, frg
		local seg

		if size < IKCP_OVERHEAD then break end

		conv = ikcp_decode32u(data)

		if conv ~= kcp.conv then return -1 end

		cmd = ikcp_decode8u(data)
		frg = ikcp_decode8u(data)
		wnd = ikcp_decode16u(data)
		ts = ikcp_decode32u(data)
		sn = ikcp_decode32u(data)
		una = ikcp_decode32u(data)
		len = ikcp_decode32u(data)

		size = size - IKCP_OVERHEAD

		if size < len or len < 0 then return -2 end

		if cmd ~= IKCP_CMD_PUSH and cmd ~= IKCP_CMD_ACK and cmd ~= IKCP_CMD_WASK and cmd ~= IKCP_CMD_WINS
		then return -3 end

		kcp.rmt_wnd = wnd
		ikcp_parse_una(kcp, una)
		ikcp_shrink_buf(kcp)

		if cmd == IKCP_CMD_ACK then
            local tdiff = _itimediff(kcp.current, ts)

			if tdiff >= 0 then
				ikcp_update_ack(kcp, tdiff)
            end

			ikcp_parse_ack(kcp, sn)
			ikcp_shrink_buf(kcp)

			if flag == 0 then
				flag = 1
				maxack = sn
				latest_ts = ts
            else
				if _itimediff(sn, maxack) > 0 then
                    if not IKCP_FASTACK_CONSERVE then
                        maxack = sn
                        latest_ts = ts
                    else
                        if _itimediff(ts, latest_ts) > 0 then
                            maxack = sn
                            latest_ts = ts
                        end
                    end
				end
			end

			if ikcp_canlog(kcp, IKCP_LOG_IN_ACK) then
				ikcp_log(kcp, IKCP_LOG_IN_ACK, 
					"input ack: sn=%d rtt=%d rto=%d", sn, 
					_itimediff(kcp.current, ts),
					kcp.rx_rto
                )
            end
		elseif cmd == IKCP_CMD_PUSH then
			if ikcp_canlog(kcp, IKCP_LOG_IN_DATA) then
				ikcp_log(kcp, IKCP_LOG_IN_DATA, 
					"input psh: sn=%d ts=%d", sn, ts)
            end

			if _itimediff(sn, kcp.rcv_nxt + kcp.rcv_wnd) < 0 then
				ikcp_ack_push(kcp, sn, ts)

				if _itimediff(sn, kcp.rcv_nxt) >= 0 then
					seg = ikcp_segment_new(kcp, len)

					seg.conv = conv;
					seg.cmd = cmd;
					seg.frg = frg;
					seg.wnd = wnd;
					seg.ts = ts;
					seg.sn = sn;
					seg.una = una;
					seg.len = len;

					if len > 0 then
                        seg.data.insert(seg.data, 1, data)
                    end

					ikcp_parse_data(kcp, seg)
				end
			end
		elseif cmd == IKCP_CMD_WASK then
			-- ready to send back IKCP_CMD_WINS in ikcp_flush
			-- tell remote my window size

			kcp.probe = bit.bor(kcp.probe, IKCP_ASK_TELL)

			if ikcp_canlog(kcp, IKCP_LOG_IN_PROBE) then
				ikcp_log(kcp, IKCP_LOG_IN_PROBE, "input probe")
            end
        elseif cmd == IKCP_CMD_WINS then
			-- do nothing
			if ikcp_canlog(kcp, IKCP_LOG_IN_WINS) then
				ikcp_log(kcp, IKCP_LOG_IN_WINS,
					"input wins: %d", wnd
                )
            end
		else return -3 end

		data = data + len
		size = size - len
	end

	if flag ~= 0 then
		ikcp_parse_fastack(kcp, maxack, latest_ts)
    end

	if _itimediff(kcp.snd_una, prev_una) > 0 then
		if kcp.cwnd < kcp.rmt_wnd then
			local mss = kcp.mss

			if kcp.cwnd < kcp.ssthresh then
				kcp.cwnd = kcp.cwnd + 1
				kcp.incr = kcp.incr + mss
			else
				if kcp.incr < mss then kcp.incr = mss end
				kcp.incr = math.floor(kcp.incr + (mss * mss) / kcp.incr + (mss / 16))
				if (kcp.cwnd + 1) * mss <= kcp.incr then
                    if true then
                        kcp.cwnd = math.floor((kcp.incr + mss - 1) / ((mss > 0) and mss or 1))
                    else
                        kcp.cwnd = kcp.cwnd + 1
                    end
                end
			end

			if kcp.cwnd > kcp.rmt_wnd then
				kcp.cwnd = kcp.rmt_wnd
				kcp.incr = kcp.rmt_wnd * mss
            end
		end
	end

	return 0
end

local function ikcp_update(kcp, current)
	local slap

	kcp.current = current

	if kcp.updated == 0 then
		kcp.updated = 1
		kcp.ts_flush = kcp.current
    end

	slap = _itimediff(kcp.current, kcp.ts_flush)

	if slap >= 10000 or slap < -10000 then
		kcp.ts_flush = kcp.current
		slap = 0
    end

	if slap >= 0 then
		kcp.ts_flush = kcp.ts_flush + kcp.interval

		if _itimediff(kcp.current, kcp.ts_flush) >= 0 then
			kcp.ts_flush = kcp.current + kcp.interval
        end

		ikcp_flush(kcp)
	end
end

local function ikcp_check(kcp, current)
	local ts_flush = kcp.ts_flush
	local tm_flush = 0x7fffffff
	local tm_packet = 0x7fffffff
	local minimal = 0
	local p

	if kcp.updated == 0 then
		return current
    end

	if _itimediff(current, ts_flush) >= 10000 or
		_itimediff(current, ts_flush) < -10000 then
		ts_flush = current
        end

	if _itimediff(current, ts_flush) >= 0 then
		return current
    end

	tm_flush = _itimediff(ts_flush, current)

    p = kcp.snd_buf.next

    repeat
		local seg = p.value
		local diff = _itimediff(seg.resendts, current)

		if diff <= 0 then return current end

		if diff < tm_packet then tm_packet = diff end

        p = p.next
    until p == kcp.snd_buf

	minimal = bit.band(0xFFFFFFFF, (tm_packet < tm_flush) and tm_packet or tm_flush)

	if minimal >= kcp.interval then minimal = kcp.interval end

	return current + minimal;
end

local function ikcp_flush(kcp)
	local current = kcp.current
	local buffer = kcp.buffer
	local ptr = buffer

	local count, size
	local resent, cwnd
	local rtomin
	local p
	local change, lost = 0, 0
	
    local seg = { }

    local offset = 0

	-- 'ikcp_update' haven't been called. 
	if kcp.updated == 0 then return end

	seg.conv = kcp.conv
	seg.cmd = IKCP_CMD_ACK
	seg.frg = 0
	seg.wnd = ikcp_wnd_unused(kcp)
	seg.una = kcp.rcv_nxt
	seg.len = 0
	seg.sn = 0
	seg.ts = 0

	-- flush acknowledges
	count = kcp.ackcount

    local tmpSegBuffer = ikcp_malloc(24)

	for i = 1, count do
		size = offset

		if size + IKCP_OVERHEAD > kcp.mtu then
			ikcp_output(kcp, buffer, size)
			offset = 0
        end

		seg.sn, seg.ts = ikcp_ack_get(kcp, i - 1, seg.sn, seg.ts)

		ikcp_encode_seg(tmpSegBuffer, seg)

        buffer.insert(buffer, offset, tmpSegBuffer)

        tmpSegBuffer.clear(tmpSegBuffer)

        offset = offset + 24
	end

	kcp.ackcount = 0

	-- probe window size (if remote window size equals zero)
	if kcp.rmt_wnd == 0 then
		if kcp.probe_wait == 0 then
			kcp.probe_wait = IKCP_PROBE_INIT
			kcp.ts_probe = kcp.current + kcp.probe_wait
		else
			if _itimediff(kcp.current, kcp.ts_probe) >= 0 then
				if kcp.probe_wait < IKCP_PROBE_INIT then
					kcp.probe_wait = IKCP_PROBE_INIT
                end
				kcp.probe_wait = math.floor(kcp.probe_wait + kcp.probe_wait / 2)
				if kcp.probe_wait > IKCP_PROBE_LIMIT then
					kcp.probe_wait = IKCP_PROBE_LIMIT
                end
				kcp.ts_probe = kcp.current + kcp.probe_wait
				kcp.probe = bit.bor(kcp.probe, IKCP_ASK_SEND)
            end
		end
	else
		kcp.ts_probe = 0
		kcp.probe_wait = 0
    end

	-- flush window probing commands
	if bit.band(kcp.probe, IKCP_ASK_SEND) ~= 0 then
		seg.cmd = IKCP_CMD_WASK
		size = offset
		if size + IKCP_OVERHEAD > kcp.mtu then
			ikcp_output(kcp, buffer, size)
			offset = 0
        end

		ikcp_encode_seg(tmpSegBuffer, seg)

        buffer.insert(buffer, offset, tmpSegBuffer)

        tmpSegBuffer.clear(tmpSegBuffer)

        offset = offset + 24
	end

	-- flush window probing commands
	if bit.band(kcp.probe, IKCP_ASK_TELL) ~= 0 then
		seg.cmd = IKCP_CMD_WINS
		size = offset
		if size + IKCP_OVERHEAD > kcp.mtu then
			ikcp_output(kcp, buffer, size)
			offset = 0
        end

		ikcp_encode_seg(tmpSegBuffer, seg)

        buffer.insert(buffer, offset, tmpSegBuffer)

        tmpSegBuffer.clear(tmpSegBuffer)

        offset = offset + 24
	end

	kcp.probe = 0

	-- calculate window size
	cwnd = math.min(kcp.snd_wnd, kcp.rmt_wnd)
	if kcp.nocwnd == 0 then cwnd = math.min(kcp.cwnd, cwnd) end

	-- move data from snd_queue to snd_buf
	while _itimediff(kcp.snd_nxt, kcp.snd_una + cwnd) < 0 do
		local newseg

		if iqueue_is_empty(kcp.snd_queue) then break end

		newseg = kcp.ssnd_queue.next.value

		iqueue_del(newseg.node)
		iqueue_add_tail(newseg.node, kcp.snd_buf)
		kcp.nsnd_que = kcp.nsnd_que - 1
		kcp.nsnd_buf = kcp.nsnd_buf + 1

		newseg.conv = kcp.conv
		newseg.cmd = IKCP_CMD_PUSH
		newseg.wnd = seg.wnd
		newseg.ts = current
		newseg.sn = kcp.snd_nxt
		kcp.snd_nxt = kcp.snd_nxt + 1
		newseg.una = kcp.rcv_nxt
		newseg.resendts = current
		newseg.rto = kcp.rx_rto
		newseg.fastack = 0
		newseg.xmit = 0
	end

	-- calculate resent
	resent = (kcp.fastresend > 0) and kcp.fastresend or 0xffffffff
	rtomin = (kcp.nodelay == 0) and bit.rshift(kcp.rx_rto, 3) or 0

	-- flush data segments
	p = kcp.snd_buf.next

	repeat
		local segment = p.value
		local needsend = 0

		if segment.xmit == 0 then
			needsend = 1
			segment.xmit = segment.xmit + 1
			segment.rto = kcp.rx_rto
			segment.resendts = current + segment.rto + rtomin
		elseif _itimediff(current, segment.resendts) >= 0 then
			needsend = 1
			segment.xmit = segment.xmit + 1
			kcp.xmit = kcp.xmit + 1
			if kcp.nodelay == 0 then
				segment.rto = segment.rto + math.max(segment.rto, kcp.rx_rto)
			else
				local step = (kcp.nodelay < 2) and 
					(segment.rto) or kcp.rx_rto
				segment.rto = math.floor(segment.rto + step / 2)
			end
			segment.resendts = current + segment.rto
			lost = 1
		elseif segment.fastack >= resent then
			if segment.xmit <= kcp.fastlimit or
				kcp.fastlimit <= 0 then
				needsend = 1
				segment.xmit = segment.xmit + 1
				segment.fastack = 0
				segment.resendts = current + segment.rto
				change = change + 1
			end
		end

		if needsend then
			local need
			segment.ts = current
			segment.wnd = seg.wnd
			segment.una = kcp.rcv_nxt

			size = offset
			need = IKCP_OVERHEAD + segment.len

			if size + need > kcp.mtu then
				ikcp_output(kcp, buffer, size)
				offset = 0
			end

			ikcp_encode_seg(tmpSegBuffer, segment)

			buffer.insert(buffer, offset, tmpSegBuffer)

			tmpSegBuffer.clear(tmpSegBuffer)

			offset = offset + 24

			if segment.len > 0 then
				for i = 1, segment.len do
					buffer[i + offset] = segment.data[i]
				end

				offset = offset + segment.len
			end

			if segment.xmit >= kcp.dead_link then
				kcp.state = 0xFFFFFFFF
			end
		end

		p = p.next
	until p == kcp.snd_buf

	-- flash remain segments
	size = offset
	if size > 0 then
		ikcp_output(kcp, buffer, size);
	end

	-- update ssthresh
	if change then
		local inflight = bit.band(0xFFFFFFFF, kcp.snd_nxt - kcp.snd_una)
		kcp.ssthresh = math.floor(inflight / 2)
		if kcp.ssthresh < IKCP_THRESH_MIN then
			kcp.ssthresh = IKCP_THRESH_MIN
		end
		kcp.cwnd = kcp.ssthresh + resent
		kcp.incr = kcp.cwnd * kcp.mss
	end

	if lost then
		kcp.ssthresh = math.floor(cwnd / 2)
		if kcp.ssthresh < IKCP_THRESH_MIN then
			kcp.ssthresh = IKCP_THRESH_MIN
		end
		kcp.cwnd = 1
		kcp.incr = kcp.mss
	end

	if kcp.cwnd < 1 then
		kcp.cwnd = 1
		kcp.incr = kcp.mss
	end
end

local function ikcp_setmtu(kcp, mtu)
	local buffer
	if mtu < 50 or mtu < IKCP_OVERHEAD then
		return -1
	end
	buffer = ikcp_malloc((mtu + IKCP_OVERHEAD) * 3)
	if buffer == NULL then
		return -2
	end
	kcp.mtu = mtu
	kcp.mss = kcp.mtu - IKCP_OVERHEAD
	ikcp_free(kcp.buffer)
	kcp.buffer = buffer
	return 0
end

local function ikcp_wndsize(kcp, sndwnd, rcvwnd)
	if kcp then
		if sndwnd > 0 then
			kcp.snd_wnd = sndwnd
		end
		if rcvwnd > 0 then   -- must >= max fragment size
			kcp.rcv_wnd = math.max(rcvwnd, IKCP_WND_RCV)
		end
	end
	return 0
end

local function ikcp_waitsnd(kcp)
	return kcp.nsnd_buf + kcp.nsnd_que
end

local function ikcp_nodelay(kcp, nodelay, interval, resend, nc)
	if nodelay >= 0 then
		kcp.nodelay = nodelay
		if nodelay then
			kcp.rx_minrto = IKCP_RTO_NDL
		else
			kcp.rx_minrto = IKCP_RTO_MIN
		end
	end
	if interval >= 0 then
		if interval > 5000 then interval = 5000
		elseif interval < 10 then interval = 10 end
		kcp.interval = interval
	end
	if resend >= 0 then
		kcp.fastresend = resend
	end
	if nc >= 0 then
		kcp.nocwnd = nc
	end
	return 0
end

local function ikcp_getconv(data)
	return UNPACK(32, { data[1], data[2], data[3], data[4] })
end

local function ikcp_allocator(new_malloc, new_free)
	MALLOC = new_malloc or DEFAULT_MALLOC
	FREE = new_free or DEFAULT_FREE
end

local function luaikcp_pack(new_pack, new_unpack)
	PACK = new_pack or DEFAULT_PACK
	UNPACK = new_unpack or DEFAULT_UNPACK
end

return
{
    ikcp_create = ikcp_create,
    ikcp_release = ikcp_release,
    ikcp_setoutput = ikcp_setoutput,

    ikcp_send = ikcp_send,
    ikcp_recv = ikcp_recv,
    ikcp_peeksize = ikcp_peeksize,

    ikcp_input = ikcp_input,
    ikcp_update = ikcp_update,
    ikcp_check = ikcp_check,
	ikcp_flush = ikcp_flush,

	ikcp_setmtu = ikcp_setmtu,
	ikcp_wndsize = ikcp_wndsize,
	ikcp_waitsnd = ikcp_waitsnd,
	ikcp_nodelay = ikcp_nodelay,

	ikcp_log = ikcp_log,
	ikcp_allocator = ikcp_allocator,
	ikcp_getconv = ikcp_getconv,

	luaikcp_pack = luaikcp_pack,

    IKCP_LOG_OUTPUT = IKCP_LOG_OUTPUT,
    IKCP_LOG_INPUT = IKCP_LOG_INPUT,
    IKCP_LOG_SEND = IKCP_LOG_SEND,
    IKCP_LOG_RECV = IKCP_LOG_RECV,
    IKCP_LOG_IN_DATA = IKCP_LOG_IN_DATA,
    IKCP_LOG_IN_ACK = IKCP_LOG_IN_ACK,
    IKCP_LOG_IN_PROBE = IKCP_LOG_IN_PROBE,
    IKCP_LOG_IN_WINS = IKCP_LOG_IN_WINS,
    IKCP_LOG_OUT_DATA = IKCP_LOG_OUT_DATA,
    IKCP_LOG_OUT_ACK = IKCP_LOG_OUT_ACK,
    IKCP_LOG_OUT_PROBE = IKCP_LOG_OUT_PROBE,
    IKCP_LOG_OUT_WINS = IKCP_LOG_OUT_WINS
}