const std = @import("std");
const vapoursynth = @import("vapoursynth");

const math = std.math;
const vs = vapoursynth.vapoursynth4;
const zapi = vapoursynth.zigapi;

const allocator = std.heap.c_allocator;

const Data = struct {
    node: ?*vs.Node,
    vi: *const vs.VideoInfo,
};

const ConvMode = enum(i32) {
    XYZTOOKLAB = 0,
    OKLABTOXYZ = 1,
};

fn xyzToOklab(xyz: [3]f32) [3]f32 {
    const lms = [3]f32{
        math.cbrt(0.8189330101 * xyz[0] + 0.3618667424 * xyz[1] - 0.1288597137 * xyz[2]),
        math.cbrt(0.0329845436 * xyz[0] + 0.9293118715 * xyz[1] + 0.0361456387 * xyz[2]),
        math.cbrt(0.0482003018 * xyz[0] + 0.2643662691 * xyz[1] + 0.6338517070 * xyz[2]),
    };

    const oklab = [3]f32{
        0.2104542553 * lms[0] + 0.7936177850 * lms[1] - 0.0040720468 * lms[2],
        1.9779984951 * lms[0] - 2.4285922050 * lms[1] + 0.4505937099 * lms[2],
        0.0259040371 * lms[0] + 0.7827717662 * lms[1] - 0.8086757660 * lms[2],
    };

    return oklab;
}

fn oklabToXyz(oklab: [3]f32) [3]f32 {
    const lms = [3]f32{
        oklab[0] + 0.3963377774 * oklab[1] + 0.2158037573 * oklab[2],
        oklab[0] - 0.1055613458 * oklab[1] - 0.0638541728 * oklab[2],
        oklab[0] - 0.0894841775 * oklab[1] - 1.2914855480 * oklab[2],
    };

    const lms_cubed = [3]f32{
        lms[0] * lms[0] * lms[0],
        lms[1] * lms[1] * lms[1],
        lms[2] * lms[2] * lms[2],
    };

    const xyz = [3]f32{
        lms_cubed[0] * 1.2270138511 + lms_cubed[1] * -0.5577999807 + lms_cubed[2] * 0.2812561490,
        lms_cubed[0] * -0.0405801784 + lms_cubed[1] * 1.1122568696 + lms_cubed[2] * -0.0716766787,
        lms_cubed[0] * -0.0763812845 + lms_cubed[1] * -0.4214819784 + lms_cubed[2] * 1.5861632204,
    };

    return xyz;
}

fn VSTEST(comptime mode: ConvMode) type {
    return struct {
        pub fn getFrame(n: c_int, activation_reason: vs.ActivationReason, instance_data: ?*anyopaque, frame_data: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) ?*const vs.Frame {
            _ = frame_data;
            const d: *Data = @ptrCast(@alignCast(instance_data));

            if (activation_reason == .Initial) {
                vsapi.?.requestFrameFilter.?(n, d.node, frame_ctx);
            } else if (activation_reason == .AllFramesReady) {
                var src = zapi.Frame.init(d.node, n, frame_ctx, core, vsapi);
                defer src.deinit();
                const dst = src.newVideoFrame();

                const srcpR: [*]const f32 = @ptrCast(@alignCast(src.getReadSlice(0)));
                const srcpG: [*]const f32 = @ptrCast(@alignCast(src.getReadSlice(1)));
                const srcpB: [*]const f32 = @ptrCast(@alignCast(src.getReadSlice(2)));

                const dstpL: [*]f32 = @ptrCast(@alignCast(dst.getWriteSlice(0)));
                const dstpA: [*]f32 = @ptrCast(@alignCast(dst.getWriteSlice(1)));
                const dstpB: [*]f32 = @ptrCast(@alignCast(dst.getWriteSlice(2)));
                const w, const h, var stride = src.getDimensions(0);
                stride = @divTrunc(stride, @sizeOf(f32));

                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    const srcpR_row = srcpR + y * stride;
                    const srcpG_row = srcpG + y * stride;
                    const srcpB_row = srcpB + y * stride;
                    var dstpR_row = dstpL + y * stride;
                    var dstpG_row = dstpA + y * stride;
                    var dstpB_row = dstpB + y * stride;

                    var x: u32 = 0;
                    while (x < w) : (x += 1) {
                        const rgb = [3]f32{ srcpR_row[x], srcpG_row[x], srcpB_row[x] };
                        const convertedColor: [3]f32 = switch (mode) {
                            .XYZTOOKLAB => xyzToOklab(rgb),
                            .OKLABTOXYZ => oklabToXyz(rgb),
                        };

                        dstpR_row[x] = convertedColor[0];
                        dstpG_row[x] = convertedColor[1];
                        dstpB_row[x] = convertedColor[2];
                    }
                }

                return dst.frame;
            }

            return null;
        }
    };
}

export fn vstestFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = core;
    const d: *Data = @ptrCast(@alignCast(instance_data));
    vsapi.?.freeNode.?(d.node);
    allocator.destroy(d);
}

export fn vstestCreate(in: ?*const vs.Map, out: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = user_data;
    var d: Data = undefined;
    var map = zapi.Map.init(in, out, vsapi);

    d.node, d.vi = map.getNodeVi("clip");

    if ((d.vi.format.sampleType != .Float) or (d.vi.format.bitsPerSample != 32) or (d.vi.format.colorFamily != .RGB)) {
        map.setError("vstest: only RGBS input supported");
        vsapi.?.freeNode.?(d.node);
        return;
    }

    const mode = map.getInt(i32, "mode") orelse 0;
    if ((mode < 0) or (mode > 1)) {
        map.setError("vstest: mode must be 0 or 1");
        vsapi.?.freeNode.?(d.node);
        return;
    }

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    var deps = [_]vs.FilterDependency{
        vs.FilterDependency{
            .source = d.node,
            .requestPattern = .StrictSpatial,
        },
    };

    const getFrame = switch (@as(ConvMode, @enumFromInt(mode))) {
        .XYZTOOKLAB => &VSTEST(.XYZTOOKLAB).getFrame,
        .OKLABTOXYZ => &VSTEST(.OKLABTOXYZ).getFrame,
    };

    vsapi.?.createVideoFilter.?(out, "vstest", d.vi, getFrame, vstestFree, .Parallel, &deps, deps.len, data, core);
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    _ = vspapi.configPlugin.?("com.example.vstest", "vstest", "VapourSynth vstest", vs.makeVersion(1, 0), vs.VAPOURSYNTH_API_VERSION, 0, plugin);
    _ = vspapi.registerFunction.?("Filter", "clip:vnode;mode:int:opt;", "clip:vnode;", vstestCreate, null, plugin);
}
