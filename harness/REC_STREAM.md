# Bounded-memory ShaderBench screen recording

Use `rec_stream.py` for visual motion captures while Minecraft is running:

```powershell
py harness/rec_stream.py 10 harness/out/storm.mp4 --fps 30
```

This captures the same secondary-monitor rectangle and half-size output as
the earlier `rec.py`. It sends each RGB frame directly to the MP4 writer
instead of keeping all frames in a list. Frame rate is fixed at capture time
and the output file is never overwritten. Use `--npy` only when exact RGB
frames are needed for offline pixel analysis; it writes a temporary raw file
and a `.npy` file in bounded RAM, so allow about twice the uncompressed video
size in free disk space while it finishes.

`rec.py` retained every 766x430 RGB frame and then copied the full recording
with `np.stack()`. At 60 FPS, 60 seconds requires about 3.6 GiB per copy,
before encoder buffers. Do not use it for long captures under the current
Windows memory pressure. `rec_stream.py` leaves Claude's original script
untouched. The real MP4 encoder and `.npy` reader are covered by
`py -m unittest test_rec_stream` from `harness/`.
