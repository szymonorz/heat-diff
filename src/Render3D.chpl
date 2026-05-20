module Render3D {
  use Image;
  use Math;

  config const render    = false;
  config const movieName = "heat3d.mp4";
  config const framerate = 10;
  config const imageH    = 512;
  config const imageW    = 512;
  config const camDist   = 2.0;
  config const rotX      = -0.5;
  config const rotY      = 0.0;
  config const pointSize  = 3;
  config const cubeScale  = 1.0;  // multiply to make the cube larger

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

  // project a normalized 3D point to (row, col) screen coords; returns (-1,-1) if behind camera
  // rotations are around the cube center (origin in normalized space): Y first, then X
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

  // Bresenham line between two screen points
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

      // For a face with outward normal (nx,ny,nz), its rotated Z component
      // (Y-then-X rotation) is: sinX*ny - cosX*sinY*nx + cosX*cosY*nz
      // A face is front-facing when this value < 0 (normal points toward camera).
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
            // skip interior voxels
            if ii != x0 && ii != x0+nx-1 &&
               jj != y0 && jj != y0+ny-1 &&
               kk != z0 && kk != z0+nz-1 then continue;

            // skip back-facing surface voxels
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

            // rotate around cube center: Y first, then X
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
              // boundary voxels are never updated by the solver — sample one
              // step inward, but only along each axis that is front-facing.
              // This preserves boundary conditions on non-visible faces
              // (e.g. the hot base stays hot on an adjacent visible face).
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

      // pass 2: depth-aware dilation — a voxel may only expand into a pixel
      // if it is closer (smaller Z) than whatever is already there.
      // This prevents back-facing voxels from bleeding into front-face territory.
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
      // each edge borders two faces; draw only if at least one is front-facing
      // 4 x-parallel edges (faceMinY/faceMaxY × faceMinZ/faceMaxZ)
      if faceMinY || faceMinZ then edge(-0.5,-0.5,-0.5,  0.5,-0.5,-0.5);
      if faceMaxY || faceMinZ then edge(-0.5, 0.5,-0.5,  0.5, 0.5,-0.5);
      if faceMinY || faceMaxZ then edge(-0.5,-0.5, 0.5,  0.5,-0.5, 0.5);
      if faceMaxY || faceMaxZ then edge(-0.5, 0.5, 0.5,  0.5, 0.5, 0.5);
      // 4 y-parallel edges (faceMinX/faceMaxX × faceMinZ/faceMaxZ)
      if faceMinX || faceMinZ then edge(-0.5,-0.5,-0.5, -0.5, 0.5,-0.5);
      if faceMaxX || faceMinZ then edge( 0.5,-0.5,-0.5,  0.5, 0.5,-0.5);
      if faceMinX || faceMaxZ then edge(-0.5,-0.5, 0.5, -0.5, 0.5, 0.5);
      if faceMaxX || faceMaxZ then edge( 0.5,-0.5, 0.5,  0.5, 0.5, 0.5);
      // 4 z-parallel edges (faceMinX/faceMaxX × faceMinY/faceMaxY)
      if faceMinX || faceMinY then edge(-0.5,-0.5,-0.5, -0.5,-0.5, 0.5);
      if faceMaxX || faceMinY then edge( 0.5,-0.5,-0.5,  0.5,-0.5, 0.5);
      if faceMinX || faceMaxY then edge(-0.5, 0.5,-0.5, -0.5, 0.5, 0.5);
      if faceMaxX || faceMaxY then edge( 0.5, 0.5,-0.5,  0.5, 0.5, 0.5);

      pipe.writeFrame(dilated);
    }
  }
}
