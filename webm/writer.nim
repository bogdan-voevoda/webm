import webm

proc encode_frame(codec: ptr vpx_codec_ctx_t, img: ptr vpx_image_t,
                    frame_index, flags: cint,
                    rate_hist: rate_hist_t,
                    cfg: ptr vpx_codec_enc_cfg_t,
                    ctx: ptr WebmOutputContext): bool =
  var iter: vpx_codec_iter_t
  var pkt: ptr vpx_codec_cx_pkt_t

  let res = vpx_codec_encode(codec, img, frame_index, 1, flags, VPX_DL_GOOD_QUALITY)
  if (res != 0):
    raise newException(Exception, "Failed to encode frame")

  while true:
    pkt = vpx_codec_get_cx_data(codec, addr iter)
    if pkt.isNil: break
    result = true

    if (pkt.kind == VPX_CODEC_CX_FRAME_PKT):
      let keyframe = (pkt.data.frame.flags and VPX_FRAME_IS_KEY) != 0
      update_rate_histogram(rate_hist, cfg, pkt);
      write_webm_block(ctx, cfg, pkt)

      echo if keyframe: "K" else: "."

when isMainModule:
    proc testDecode() =
        var webmctx: WebmInputContext
        var vpxctx: VpxInputContext
        var input: VpxDecInputContext
        input.vpx_input_ctx = addr vpxctx
        input.webm_ctx = addr webmctx
        vpxctx.file = open("output.webm")
        vpxctx.file_type = FILE_TYPE_WEBM
        echo file_is_webm(input.webm_ctx, input.vpx_input_ctx)
        echo webm_guess_framerate(input.webm_ctx, input.vpx_input_ctx)
        var decoder: vpx_codec_ctx_t

        var cfg: vpx_codec_dec_cfg_t

        let i = vpx_codec_dec_init_ver(addr decoder, vpx_codec_vp9_dx(), addr cfg, 0)
        if i != 0:
            echo vpx_codec_error(addr decoder)


        var buf: ptr uint8
        var bytes_in_buffer: csize

        var flush_decoder = false
        if webm_read_frame(input.webm_ctx, addr buf, addr bytes_in_buffer) == 0:
            let res = vpx_codec_decode(addr decoder, buf, cuint(bytes_in_buffer), nil, 0)
            if res != 0:
                echo "decode error: ", res, ": ", vpx_codec_error_detail(addr decoder)
        else:
            flush_decoder = true

        if flush_decoder:
            if vpx_codec_decode(addr decoder, nil, 0, nil, 0) != 0:
                echo "Failed to flush decoder"

        var got_data = false
        var iter: vpx_codec_iter_t
        let img = vpx_codec_get_frame(addr decoder, addr iter)
        if not img.isNil:
            echo "Got DATA!"
            if (img.fmt and VPX_IMG_FMT_PLANAR) != 0:
                echo "PLANAR"
            if img.fmt == VPX_IMG_FMT_I420:
                echo "VPX_IMG_FMT_I420"
            echo img.fmt
            echo img.cs
            echo img.rng

#    testDecode()

    import nimPNG, random, imgtools.imgtools

    proc testEncode() =
        var cfg: vpx_codec_enc_cfg_t
        var codec: vpx_codec_ctx_t
        var raw: vpx_image_t
        var ctx: WebmOutputContext
        ctx.last_pts_ns = -1

        const bitrate = 2000

        let max_frames = 0

        let width = 600
        let height = 540
        var fps: VpxRational
        fps.numerator = 1
        fps.denominator = 30

        if vpx_img_alloc(addr raw, VPX_IMG_FMT_I420, cuint(width), cuint(height), 1) == nil:
            raise newException(Exception, "Could not alloc image")

        let keyframe_interval = 0

        var res = vpx_codec_enc_config_default(vpx_codec_vp9_cx(), addr cfg, 0)
        if res != 0:
            raise newException(Exception, "vpx_codec_enc_config_default")

        cfg.g_w = cuint(width)
        cfg.g_h = cuint(height)
        cfg.g_timebase = fps
        cfg.rc_target_bitrate = bitrate
        cfg.g_error_resilient = 0

        let rh = init_rate_histogram(addr cfg, addr fps)

        var pixel_aspect_ratio: VpxRational
        pixel_aspect_ratio.numerator = 1
        pixel_aspect_ratio.denominator = 1

        ctx.stream = open("out.webm", fmWrite)
        write_webm_file_header(addr ctx,
                            addr cfg,
                            addr fps,
                            0,
                            VP9_FOURCC,
                            addr pixel_aspect_ratio)

        const totalFrames = 404

        const chapters = { "enter": 0,
                            "spin_1": 23,
                            "spin_2": 43,
                            "spin_3": 87,
                            "nowin": 145,
                            "anticipation": 162,
                            "win": 196,
                            "multiwin": 217,
                            "gotobonus": 244,
                            "run_loop_start": 251,
                            "run_loop_end": 266,
                            "wild": 298,
                            "idle": 330,
                            "scatter": 368
                        }

        template frameToTime(f: int): uint64 = uint64(f) * 33333333

        for i in 0 ..< chapters.len:
            var endTime: uint64
            if i < chapters.len - 1:
                endTime = frameToTime(chapters[i + 1][1])
            else:
                endTime = frameToTime(totalFrames)

            write_webm_chapter(addr ctx, chapters[i][0], frameToTime(chapters[i][1]), endTime)

        if vpx_codec_enc_init_ver(addr codec, vpx_codec_vp9_cx(), addr cfg, 0) != 0:
            raise newException(Exception, "Failed to initialize encoder")

        const encodeAlphaToY = true

        when encodeAlphaToY:
            proc encode(y, a: float): uint8 =
                let yy = uint8(y * 63)
                let aa = uint8(a * 3)
                result = (aa shl 6) or yy

        var curFr = 0
        proc nextFrame(img: ptr vpx_image_t): bool =
            if curFr > 404: return false
            echo "fr: ", curFr

            var idx = $curFr
            while idx.len < 5: idx = "0" & idx
            let p = loadPNG32("/Users/yglukhov/Projects/falcon/res/slots/candy_slot/boy/assets/Boy_candy_" & idx & ".png")

            for y in 0 ..< height:
                for x in 0 ..< width:
                    let sR = int32(cast[uint8](p.data[(y * width + x) * 4]))
                    let sG = int32(cast[uint8](p.data[(y * width + x) * 4 + 1]))
                    let sB = int32(cast[uint8](p.data[(y * width + x) * 4 + 2]))
                    let sA = int32(cast[uint8](p.data[(y * width + x) * 4 + 3]))

                    var yy = cast[uint8]( (66*sR + 129*sG + 25*sB + 128) shr 8) + 16
                    let uu = cast[uint8]( (-38*sR - 74*sG + 112*sB + 128) shr 8) + 128
                    let vv = cast[uint8]( (112*sR - 94*sG - 18*sB + 128) shr 8) + 128

                    when encodeAlphaToY:
                        yy = encode(yy.float / 255, sA / 255)

                    let py = cast[ptr uint8](cast[uint](img.planes[0]) + uint(y * img.stride[0] + x))
                    py[] = uint8(yy)
                    let pu = cast[ptr uint8](cast[uint](img.planes[1]) + uint((y div 2) * img.stride[1] + (x div 2)))
                    pu[] = uint8(uu)
                    let pv = cast[ptr uint8](cast[uint](img.planes[2]) + uint((y div 2) * img.stride[2] + (x div 2)))
                    pv[] = uint8(vv)

            result = true
            inc curFr
        var frame_count: cint
        var frames_encoded = 0
        while nextFrame(addr raw):
            var flags: cint
            for c in chapters:
                if frame_count == c[1]:
                    flags = VPX_EFLAG_FORCE_KF
                    break
#            if (keyframe_interval > 0 and frame_count mod keyframe_interval == 0):
#              flags = VPX_EFLAG_FORCE_KF
            discard encode_frame(addr codec, addr raw, frame_count, flags, rh, addr cfg, addr ctx)
            inc frame_count
            inc frames_encoded
            if max_frames > 0 and frames_encoded >= max_frames:
              break

        while encode_frame(addr codec, nil, -1, 0, rh, addr cfg, addr ctx): discard

        vpx_img_free(addr raw)
        write_webm_file_footer(addr ctx)
        destroy_rate_histogram(rh)

    testEncode()