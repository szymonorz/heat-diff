module ImageUtils {
  public use Image;
  use Math;

  // shared rendering config (1D/2D heatmaps and the 3D voxel renderer)
  config const render = false;
  config const movieName = "heat.mp4";
  config const framerate = 10;

  // 1D/2D heatmap output size
  config const imageHeight = 256;
  config const imageWidth = 512;

  // 3D voxel renderer
  config const imageH    = 512;
  config const imageW    = 512;
  config const camDist   = 2.0;
  config const rotX      = -0.5;
  config const rotY      = 0.0;
  config const pointSize = 3;
  config const cubeScale = 1.0;

  // ─────────────────────────────────────────────────────────────
  // 1D / 2D heatmap rendering
  // ─────────────────────────────────────────────────────────────
  proc makeEvenSize(img: [] int) {
    const H = img.domain.dim(0).size;
    const W = img.domain.dim(1).size;

    const newH = (if H % 2 == 0 then H else H+1);
    const newW = (if W % 2 == 0 then W else W+1);

    var output: [1..newH, 1..newW] int;

    for i in 1..newH do
        for j in 1..newW do
            output[i, j] = if i <= H && j <= W then img[i, j] else 0;

    return output;
  }

  proc resizeNearest(src: [] int, targetH: int, targetW: int) {
    const H = src.domain.dim(0).size,
            W = src.domain.dim(1).size;

    var output: [1..targetH, 1..targetW] int;

    for i in 1..targetH {
        const y = ((i-1):real * (H-1):real) / (targetH-1):real;
        const iy = max(1, min(H, round(y):int));

        for j in 1..targetW {
            const x = ((j-1):real * (W-1):real) / (targetW-1):real;
            const ix = max(1, min(W, round(x):int));
            output[i, j] = src[iy, ix];
        }
    }

    return output;
  }

  private proc _interpolateColor(data: [?d] real) {
    var low  = min reduce data;
    var high = max reduce data;

    var output: [data.domain] int;

    for idx in data.domain {
        var t = (data[idx] - low) / (high - low + 1e-10);
        const hue = 240.0 * t;
        const s = 1.0;
        const v = 1.0;

        const h6 = hue / 60.0;
        const i = floor(h6):int;
        const f = h6 - i;
        const p = v*(1-s);
        const q = v*(1-f*s);
        const w = v*(1-(1-f)*s);

        var r,g,b: real;
        select (i % 6) {
        when 0 { r=v; g=w; b=p; }
        when 1 { r=q; g=v; b=p; }
        when 2 { r=p; g=v; b=w; }
        when 3 { r=p; g=q; b=v; }
        when 4 { r=w; g=p; b=v; }
        when 5 { r=v; g=p; b=q; }
        }

        output[idx] = (0xFF << 24) | ((r*255):int << 16) | ((g*255):int << 8) | (b*255):int;
    }

    return output;
  }

  private proc processFrame(data: [?d]) where d.isRectangular() && d.rank == 1 {
    var data2d: [0..#imageHeight, d.lowBound..d.highBound] data.eltType;
    for i in 0..#imageHeight do
      data2d[i,..] = data;

    return processFrame(data2d);
  }
  private proc processFrame(data: [?d]) where d.isRectangular() && d.rank == 2 {
    var image: [data.domain] int;
    image[data.domain] = _interpolateColor(data);

    var resized = resizeNearest(image, imageHeight, imageWidth);
    return makeEvenSize(resized);
  }

  proc renderFrame(u: [?d]) throws where d.rank <= 2 {
      if !render then return;
      on Locales[0] {
        @functionStatic
        ref pipe = try! new mediaPipe(movieName, imageType.bmp, framerate);
        pipe.writeFrame(processFrame(u));
      }
  }

  // ─────────────────────────────────────────────────────────────
  // 3D voxel rendering (perspective projection + wireframe)
  // ─────────────────────────────────────────────────────────────
  private proc toColor(t: real): int {
    const hue = 240.0 * t;
    const h6  = hue / 60.0;
    const qi  = floor(h6): int;
    const f   = h6 - qi;
    var r, g, b: real;
    select (qi % 6) {
      when 0 { r=1;   g=f;   b=0; }
      when 1 { r=1-f; g=1;   b=0; }
      when 2 { r=0;   g=1;   b=f; }
      when 3 { r=0;   g=1-f; b=1; }
      when 4 { r=f;   g=0;   b=1; }
      when 5 { r=1;   g=0;   b=1-f; }
    }
    return (0xFF << 24) | ((r*255):int << 16) | ((g*255):int << 8) | (b*255):int;
  }

  private proc project(xn: real, yn: real, zn: real,
                       cosX: real, sinX: real, cosY: real, sinY: real,
                       fovScale: real): (int, int) {
    const xr  =  cosY*xn + sinY*zn;
    const yr  =  yn;
    const zr  = -sinY*xn + cosY*zn;
    const xrr =  xr;
    const yrr =  cosX*yr - sinX*zr;
    const zrr =  sinX*yr + cosX*zr;
    const Z   =  zrr + camDist;
    if Z <= 0.0 then return (-1, -1);
    return (imageH/2 - (yrr/Z * fovScale): int,
            imageW/2 + (xrr/Z * fovScale): int);
  }

  private proc drawLine(ref img: [] int, pi0: int, pj0: int, pi1: int, pj1: int, color: int) {
    var di = abs(pi1 - pi0), dj = abs(pj1 - pj0);
    var si = if pi0 < pi1 then 1 else -1;
    var sj = if pj0 < pj1 then 1 else -1;
    var err = di - dj, ci = pi0, cj = pj0;
    while true {
      if 0 <= ci && ci < imageH && 0 <= cj && cj < imageW then
        img[ci, cj] = color;
      if ci == pi1 && cj == pj1 then break;
      const e2 = 2 * err;
      if e2 > -dj { err -= dj; ci += si; }
      if e2 <  di { err += di; cj += sj; }
    }
  }

  proc renderFrame(u: [?d] real) throws where d.rank == 3 {
    if !render then return;
    on Locales[0] {
      @functionStatic
      ref pipe = try! new mediaPipe(movieName, imageType.bmp, framerate);

      const nx = d.dim(0).size, ny = d.dim(1).size, nz = d.dim(2).size;
      const x0 = d.dim(0).low,  y0 = d.dim(1).low,  z0 = d.dim(2).low;
      const lo = min reduce u,   hi = max reduce u;

      const white = (0xFF << 24) | 0x00FFFFFF;
      const black = (0xFF << 24);

      var frame: [0..<imageH, 0..<imageW] int = white;
      var zbuf:  [0..<imageH, 0..<imageW] real = max(real);

      const cosX = cos(rotX), sinX = sin(rotX);
      const cosY = cos(rotY), sinY = sin(rotY);
      const fovScale = imageW * 0.4 * cubeScale;

      const faceMinX = cosX*sinY        < 0.0;  // normal (-1, 0, 0)
      const faceMaxX = -cosX*sinY       < 0.0;  // normal (+1, 0, 0)
      const faceMinY = -sinX            < 0.0;  // normal (0, -1, 0)
      const faceMaxY = sinX             < 0.0;  // normal (0, +1, 0)
      const faceMinZ = -cosX*cosY       < 0.0;  // normal (0, 0, -1)
      const faceMaxZ = cosX*cosY        < 0.0;  // normal (0, 0, +1)

      // pass 1: Z-buffer at voxel center pixels
      for ii in d.dim(0) {
        for jj in d.dim(1) {
          for kk in d.dim(2) {
            if ii != x0 && ii != x0+nx-1 &&
               jj != y0 && jj != y0+ny-1 &&
               kk != z0 && kk != z0+nz-1 then continue;

            var frontFacing = false;
            if ii == x0      then frontFacing = frontFacing || faceMinX;
            if ii == x0+nx-1 then frontFacing = frontFacing || faceMaxX;
            if jj == y0      then frontFacing = frontFacing || faceMinY;
            if jj == y0+ny-1 then frontFacing = frontFacing || faceMaxY;
            if kk == z0      then frontFacing = frontFacing || faceMinZ;
            if kk == z0+nz-1 then frontFacing = frontFacing || faceMaxZ;
            if !frontFacing then continue;

            const xn = (ii - x0): real / max(1, nx - 1) - 0.5;
            const yn = (jj - y0): real / max(1, ny - 1) - 0.5;
            const zn = (kk - z0): real / max(1, nz - 1) - 0.5;

            const xr  =  cosY*xn + sinY*zn;
            const yr  =  yn;
            const zr  = -sinY*xn + cosY*zn;
            const xrr =  xr;
            const yrr =  cosX*yr - sinX*zr;
            const zrr =  sinX*yr + cosX*zr;
            const Z   =  zrr + camDist;
            if Z <= 0.0 then continue;

            const pj = imageW/2 + (xrr/Z * fovScale): int;
            const pi = imageH/2 - (yrr/Z * fovScale): int;
            if pi < 0 || pi >= imageH || pj < 0 || pj >= imageW then continue;

            if Z < zbuf[pi, pj] {
              zbuf[pi, pj] = Z;
              // boundary voxels are never updated by the solver — sample one step inward
              // along each front-facing axis to preserve boundary conditions on visible faces
              var si = ii, sj = jj, sk = kk;
              if ii == x0      && faceMinX then si = x0+1;
              if ii == x0+nx-1 && faceMaxX then si = x0+nx-2;
              if jj == y0      && faceMinY then sj = y0+1;
              if jj == y0+ny-1 && faceMaxY then sj = y0+ny-2;
              if kk == z0      && faceMinZ then sk = z0+1;
              if kk == z0+nz-1 && faceMaxZ then sk = z0+nz-2;
              const t = (u[si, sj, sk] - lo) / (hi - lo + 1e-10);
              frame[pi, pj] = toColor(t);
            }
          }
        }
      }

      // pass 2: depth-aware dilation
      var dilated = frame;
      var zbuf2   = zbuf;
      for pi in 0..<imageH {
        for pj in 0..<imageW {
          if frame[pi, pj] != white {
            const color = frame[pi, pj];
            const z     = zbuf[pi, pj];
            for di in -pointSize..pointSize {
              for dj in -pointSize..pointSize {
                const ri = pi + di, rj = pj + dj;
                if ri < 0 || ri >= imageH || rj < 0 || rj >= imageW then continue;
                if z < zbuf2[ri, rj] {
                  zbuf2[ri, rj] = z;
                  dilated[ri, rj] = color;
                }
              }
            }
          }
        }
      }

      // pass 3: draw the 12 cube edges in black
      proc edge(x0:real, y0:real, z0:real, x1:real, y1:real, z1:real) {
        const (pi0, pj0) = project(x0, y0, z0, cosX, sinX, cosY, sinY, fovScale);
        const (pi1, pj1) = project(x1, y1, z1, cosX, sinX, cosY, sinY, fovScale);
        if pi0 >= 0 && pi1 >= 0 then
          drawLine(dilated, pi0, pj0, pi1, pj1, black);
      }
      if faceMinY || faceMinZ then edge(-0.5,-0.5,-0.5,  0.5,-0.5,-0.5);
      if faceMaxY || faceMinZ then edge(-0.5, 0.5,-0.5,  0.5, 0.5,-0.5);
      if faceMinY || faceMaxZ then edge(-0.5,-0.5, 0.5,  0.5,-0.5, 0.5);
      if faceMaxY || faceMaxZ then edge(-0.5, 0.5, 0.5,  0.5, 0.5, 0.5);
      if faceMinX || faceMinZ then edge(-0.5,-0.5,-0.5, -0.5, 0.5,-0.5);
      if faceMaxX || faceMinZ then edge( 0.5,-0.5,-0.5,  0.5, 0.5,-0.5);
      if faceMinX || faceMaxZ then edge(-0.5,-0.5, 0.5, -0.5, 0.5, 0.5);
      if faceMaxX || faceMaxZ then edge( 0.5,-0.5, 0.5,  0.5, 0.5, 0.5);
      if faceMinX || faceMinY then edge(-0.5,-0.5,-0.5, -0.5,-0.5, 0.5);
      if faceMaxX || faceMinY then edge( 0.5,-0.5,-0.5,  0.5,-0.5, 0.5);
      if faceMinX || faceMaxY then edge(-0.5, 0.5,-0.5, -0.5, 0.5, 0.5);
      if faceMaxX || faceMaxY then edge( 0.5, 0.5,-0.5,  0.5, 0.5, 0.5);

      pipe.writeFrame(dilated);
    }
  }
}
