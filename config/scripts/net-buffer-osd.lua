-- net-buffer-osd.lua
-- 网络流开屏 / 缓冲暂停显示中文提示 + Unicode 转圈 + 进度条 + 网络速度
-- 开屏阶段：显示 2 个方块来回移动
-- 缓冲暂停：显示基于 demuxer-cache-duration / TARGET_SECONDS 的比
--速度：先 demuxer-cache-state.raw-input-rate

local mp = require "mp"

-- ===== 可调参数 =====
local TARGET_CACHE_SECONDS = 30

local FONT_SIZE = 60
local BAR_WIDTH = 15

local X_OFFSET = 500
local Y_OFFSET = 250

local TIMER_INTERVAL = 0.12

local TEXT_OPENING = "正在打开"
local TEXT_BUFFERING = "正在缓冲"

local SPINNER_FRAMES = {
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
}

local BAR_FILLED = "■"
local BAR_EMPTY  = " "
local IND_BLOCKS = 2

-- ====================

local overlay = mp.create_osd_overlay("ass-events")

local timer = nil
local frame = 1
local indeterminate_pos = 1
local indeterminate_dir = 1

local file_loaded = false
local is_network = false

-- 用于 raw-input-rate 不可用时估算网络速度
local last_total_bytes = nil
local last_speed_time = nil
local estimated_speed = nil
local SPEED_SAMPLE_INTERVAL = 0.10

local function ass_escape(s)
    s = tostring(s or "")
    s = s:gsub("{", "\\{")
    s = s:gsub("}", "\\}")
    return s
end

local function is_network_path(path)
    if not path or path == "" then
        return false
    end

    path = path:lower()

    return path:match("^https?://")
        or path:match("^rtmp://")
        or path:match("^rtmps://")
        or path:match("^rtsp://")
        or path:match("^srt://")
        or path:match("^udp://")
        or path:match("^tcp://")
        or path:match("^mms://")
        or path:match("^ytdl://")
end

local function get_buffer_percent()
    local sec = mp.get_property_number("demuxer-cache-duration")

    if sec and sec >= 0 then
        local p = sec / TARGET_CACHE_SECONDS * 100
        if p > 100 then p = 100 end
        if p < 0 then p = 0 end
        return math.floor(p + 0.5)
    end

    return nil
end

local function format_speed(bytes_per_sec)
    if not bytes_per_sec or bytes_per_sec < 0 then
        return "速度：--/s"
    end

    if bytes_per_sec >= 1024 * 1024 then
        return string.format("速度：%.2f MB/s", bytes_per_sec / 1024 / 1024)
    elseif bytes_per_sec >= 1024 then
        return string.format("速度：%.1f KB/s", bytes_per_sec / 1024)
    else
        return string.format("速度：%d B/s", bytes_per_sec)
    end
end

local function estimate_speed_from_cache_state(state)
    if type(state) ~= "table" then
        return nil
    end

    local total = state["total-bytes"]
    if type(total) ~= "number" then
        return nil
    end

    local now = mp.get_time()

    if last_total_bytes and last_speed_time then
        local dt = now - last_speed_time
        local db = total - last_total_bytes

        -- 属性观察器和动画定时器可能在同一时刻重复 render。太密的样本
        -- 会把极小 dt 放大成错误的瞬时速度，因此只接受完整采样窗口。
        if dt < SPEED_SAMPLE_INTERVAL then
            return estimated_speed
        end

        if db >= 0 then
            estimated_speed = db / dt
        end
    end

    last_total_bytes = total
    last_speed_time = now

    return estimated_speed
end

local function get_network_speed_text()
    local state = mp.get_property_native("demuxer-cache-state")

    if type(state) == "table" then
        -- 优先读取 mpv 提供的原始输入速度
        local rate = state["raw-input-rate"]
        if type(rate) == "number" then
            return format_speed(rate)
        end

        -- 备用：部分 mpv 版本没有 raw-input-rate，用 total-bytes 差值估算
        local estimated = estimate_speed_from_cache_state(state)
        if estimated then
            return format_speed(estimated)
        end
    end

    -- 再尝试直接路径读取
    local rate = mp.get_property_number("demuxer-cache-state/raw-input-rate")
    if rate then
        return format_speed(rate)
    end

    return "速度：--/s"
end

local function make_bar(percent)
    if not percent then
        return "[" .. string.rep(BAR_EMPTY, BAR_WIDTH) .. "] --%"
    end

    local filled = math.floor(BAR_WIDTH * percent / 100 + 0.5)
    if filled < 0 then filled = 0 end
    if filled > BAR_WIDTH then filled = BAR_WIDTH end

    return "[" ..
        string.rep(BAR_FILLED, filled) ..
        string.rep(BAR_EMPTY, BAR_WIDTH - filled) ..
        "] " .. percent .. "%"
end

local function make_indeterminate_bar()
    local chars = {}

    for i = 1, BAR_WIDTH do
        chars[i] = BAR_EMPTY
    end

    for i = 0, IND_BLOCKS - 1 do
        local p = indeterminate_pos + i
        if p >= 1 and p <= BAR_WIDTH then
            chars[p] = BAR_FILLED
        end
    end

    indeterminate_pos = indeterminate_pos + indeterminate_dir

    local max_pos = BAR_WIDTH - IND_BLOCKS + 1
    if indeterminate_pos >= max_pos then
        indeterminate_pos = max_pos
        indeterminate_dir = -1
    elseif indeterminate_pos <= 1 then
        indeterminate_pos = 1
        indeterminate_dir = 1
    end

    return "[" .. table.concat(chars) .. "] ..."
end

local function should_show()
    if not is_network then
        return false
    end

    local idle = mp.get_property_bool("idle-active", false)
    if idle then
        return false
    end

    -- 开屏阶段显示
    if not file_loaded then
        return true
    end

    -- 缓冲暂停时显示
    if mp.get_property_bool("paused-for-cache", false) then
        return true
    end

    return false
end

local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function hide_overlay()
    overlay:remove()
end

local function reset_speed_state()
    last_total_bytes = nil
    last_speed_time = nil
    estimated_speed = nil
end

local function render()
    if not should_show() then
        hide_overlay()
        stop_timer()
        return
    end

    local w = mp.get_property_number("osd-width", 320)
    local h = mp.get_property_number("osd-height", 170)

    local x = math.floor(w / 2) + X_OFFSET
    local y = math.floor(h / 2) + Y_OFFSET

    local spin = SPINNER_FRAMES[frame]
    frame = frame + 1
    if frame > #SPINNER_FRAMES then
        frame = 1
    end

    local title
    local bar

    if not file_loaded then
        title = TEXT_OPENING
        bar = make_indeterminate_bar()
    else
        title = TEXT_BUFFERING
        bar = make_bar(get_buffer_percent())
    end

    local speed_text = get_network_speed_text()

    local line1 = ass_escape(spin .. " " .. title)
    local line2 = ass_escape(bar)
    local line3 = ass_escape(speed_text)

    overlay.data = string.format(
        "{\\an5\\pos(%d,%d)\\bord1\\shad0\\fs%d\\1c&HFFFFFF&\\3c&H000000&}%s\\N%s\\N%s",
        x,
        y,
        FONT_SIZE,
        line1,
        line2,
        line3
    )

    overlay:update()
end

local function start_timer()
    if timer then
        render()
        return
    end

    timer = mp.add_periodic_timer(TIMER_INTERVAL, render)
    render()
end

mp.register_event("start-file", function()
    file_loaded = false
    frame = 1
    indeterminate_pos = 1
    indeterminate_dir = 1
    reset_speed_state()

    local path = mp.get_property("path", "")
    is_network = is_network_path(path)

    if is_network then
        start_timer()
    else
        hide_overlay()
        stop_timer()
    end
end)

mp.register_event("file-loaded", function()
    file_loaded = true

    if should_show() then
        start_timer()
    else
        hide_overlay()
        stop_timer()
    end
end)

mp.register_event("end-file", function()
    file_loaded = false
    is_network = false
    reset_speed_state()
    hide_overlay()
    stop_timer()
end)

mp.observe_property("paused-for-cache", "bool", function(_, value)
    if not is_network then
        return
    end

    if value then
        start_timer()
    else
        render()
    end
end)

mp.observe_property("demuxer-cache-duration", "number", function()
    if is_network and timer then
        render()
    end
end)

mp.observe_property("demuxer-cache-state", "native", function()
    if is_network and timer then
        render()
    end
end)
