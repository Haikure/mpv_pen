local mp = require 'mp'
local msg = require 'mp.msg'
local opts = require 'mp.options'

local o = {
    aid = "",
    cid = "",
    bvid = "",
    part_index = "1",
    part_count = "1",
    part_duration = "0",
    type = "3",
    sub_type = "0",
    epid = "0",
    sid = "0",
    heartbeat_url = "http://127.0.0.1:8000/player/heartbeat",
    interval = 15,
    completed_cooldown = 3,
}
opts.read_options(o, "bili")

local timer = nil

-- 记录最后一次有效播放时间，避免 end-file/退出时 time-pos 被重置为 0 仍上报
local last_time_pos = nil
-- 是否已经上报完播，避免后续暂停/退出再次用普通进度覆盖 -1
local completed_reported = false
local completed_reported_at = nil

local function to_number(value, default)
    local n = tonumber(value)
    if n == nil then
        return default
    end
    return n
end

local function is_last_part()
    local part_index = to_number(o.part_index, 1)
    local part_count = to_number(o.part_count, 1)
    return part_count <= 1 or part_index >= part_count
end

local function video_duration()
    local duration = mp.get_property_number("duration", nil)
    if duration and duration > 0 then
        return math.max(1, math.floor(duration))
    end

    local part_duration = to_number(o.part_duration, 0)
    if part_duration > 0 then
        return math.max(1, math.floor(part_duration))
    end

    return nil
end

local function completed_played_time()
    if is_last_part() then
        return -1
    end

    local duration = video_duration()
    if duration then
        return duration
    end

    return last_time_pos
end

local function in_completed_cooldown()
    if not completed_reported or not completed_reported_at then
        return false
    end
    local now = mp.get_time()
    return (now - completed_reported_at) < to_number(o.completed_cooldown, 3)
end

local function is_near_end()
    local duration = mp.get_property_number("duration", nil)
    local time_pos = mp.get_property_number("time-pos", nil)

    if not duration or not time_pos then
        return false
    end

    if duration <= 0 or time_pos <= 0 then
        return false
    end

    return (duration - time_pos) <= 1.0
end

local function report_heartbeat(force_time, sync)
    local time_pos = force_time

    if time_pos == nil then
        time_pos = mp.get_property_number("time-pos", 0)
    end

    if time_pos == nil then
        return
    end

    if o.aid == "" or o.cid == "" or o.bvid == "" then
        return
    end

    local played_time = math.floor(time_pos)

    -- 完播后的一小段冷却时间内，忽略任何后续上报（如双击退出触发的 pause/shutdown）
    if in_completed_cooldown() and played_time ~= -1 then
        msg.info("heartbeat skipped because completed cooldown is active")
        return
    end

    -- 已经上报完播后，不允许普通进度覆盖 -1
    if completed_reported and played_time ~= -1 then
        msg.info("heartbeat skipped because completed already reported")
        return
    end

    -- 只缓存正常正数进度，-1 不写入缓存
    if played_time > 0 then
        last_time_pos = played_time
    end

    local duration = video_duration()
    if not duration then
        msg.info("heartbeat skipped because video duration is unavailable")
        return
    end

    -- -1 表示完播；只有实际发送时才标记，避免时长未就绪导致假完播
    if played_time == -1 then
        completed_reported = true
        completed_reported_at = mp.get_time()
    end

    local url = string.format(
        "%s?aid=%s&cid=%s&bvid=%s&played_time=%d&video_duration=%d&part_index=%s&part_count=%s&type=%s&sub_type=%s&epid=%s&sid=%s",
        o.heartbeat_url,
        o.aid,
        o.cid,
        o.bvid,
        played_time,
        duration,
        o.part_index,
        o.part_count,
        o.type,
        o.sub_type,
        o.epid,
        o.sid
    )

    msg.info("report heartbeat: " .. url)

    local cmd = {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl", "-sS",
            "--connect-timeout", "2",
            "--max-time", "5",
            url
        }
    }

    if sync then
        local result = mp.command_native(cmd)
        if not result or result.status ~= 0 then
            msg.error("heartbeat sync failed")
        end
    else
        mp.command_native_async(cmd, function(success, result, err)
            if not success then
                msg.error("heartbeat failed: " .. tostring(err))
            end
        end)
    end
end

local function start_timer()
    if completed_reported then
        return
    end

    if timer then
        timer:kill()
        timer = nil
    end

    timer = mp.add_periodic_timer(o.interval, report_heartbeat)
end

local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

mp.register_event("file-loaded", function()
    last_time_pos = nil
    completed_reported = false
    completed_reported_at = nil

    msg.info("bili heartbeat script loaded, aid=" .. o.aid .. ", cid=" .. o.cid .. ", bvid=" .. o.bvid)

    report_heartbeat()
    start_timer()
end)

mp.register_event("end-file", function(e)
    stop_timer()

    -- 正常播放完毕时，B站 heartbeat 使用 played_time=-1 表示完播
    if e and e.reason == "eof" then
        local completed_time = completed_played_time()
        if completed_time then
            report_heartbeat(completed_time, true)
        end
        return
    end

    -- 如果已经完播上报过 -1，不再上报普通进度，避免覆盖
    if completed_reported then
        return
    end

    if last_time_pos and last_time_pos > 0 then
        report_heartbeat(last_time_pos, true)
    end
end)

mp.register_event("shutdown", function()
    stop_timer()

    -- 已经上报完播，不再用退出时的旧进度覆盖
    if completed_reported then
        return
    end

    -- 退出时如果已经接近结尾，按当前分P上下文决定完播上报值
    if is_near_end() then
        local completed_time = completed_played_time()
        if completed_time then
            report_heartbeat(completed_time, true)
        end
        return
    end

    if last_time_pos and last_time_pos > 0 then
        report_heartbeat(last_time_pos, true)
    end
end)

mp.observe_property("pause", "bool", function(_, paused)
    if completed_reported then
        return
    end

    if paused then
        stop_timer()

        -- 手势退出可能先触发暂停；如果此时接近结尾，按当前分P上下文决定完播上报值
        if is_near_end() then
            local completed_time = completed_played_time()
            if completed_time then
                report_heartbeat(completed_time, true)
            end
            msg.info("paused near end, report completed heartbeat")
            return
        end

        report_heartbeat()
        msg.info("paused, heartbeat reported")
    else
        report_heartbeat()
        start_timer()
        msg.info("resumed, heartbeat reported")
    end
end)

mp.register_event("seek", function()
    if completed_reported then
        return
    end

    report_heartbeat()
    msg.info("seek, heartbeat reported")
end)
