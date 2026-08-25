# # smallpt, a Crystal path tracer
#
# This is a port of [smallpt](http://www.kevinbeason.com/smallpt/), Kevin
# Beason's famous ~100-line C++ global illumination renderer. The goal of this
# project is not just to have the algorithm in Crystal, but to compare how
# fast an idiomatic, readable Crystal implementation can be against the
# original optimized C++.
#
# The renderer is *unbiased*: it shoots random rays from the camera, follows
# them as they bounce around the scene, and averages the results. With enough
# samples, the image converges to the physically correct one.
#
# Usage: `smallpt <samples>` renders `image.ppm` at 1024x768 using
# `<samples>` subpixel passes (so `400` means 100 samples per pixel).
require "math"
require "wait_group"

# ## Vectors
#
# Everything in a path tracer starts with 3D vectors. In C++ smallpt these are
# a struct with overloaded operators; in Crystal a `record` gives us an
# immutable, stack-allocated value type — no garbage collection pressure in
# the hot loop, which is crucial for performance.
record(Vec, x : Float64 = 0.0, y : Float64 = 0.0, z : Float64 = 0.0) do
  def +(other : Vec)
    Vec.new(x + other.x, y + other.y, z + other.z)
  end

  def -(other : Vec)
    Vec.new(x - other.x, y - other.y, z - other.z)
  end

  def *(other : Float64)
    Vec.new(x * other, y * other, z * other)
  end

  # Component-wise multiplication, used to modulate light color by surface
  # color as rays bounce.
  def mult(other : Vec)
    Vec.new(x * other.x, y * other.y, z * other.z)
  end

  # Scale to unit length.
  def norm
    inverse_length = 1.0 / Math.sqrt(x * x + y * y + z * z)
    self * inverse_length
  end

  def dot(other : Vec)
    x * other.x + y * other.y + z * other.z
  end

  # Cross product. The C++ original overloads `%` for this; we keep the same
  # operator for fidelity.
  def %(other : Vec)
    Vec.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
  end
end

# A ray is just an origin and a direction.
record(Ray, o : Vec, d : Vec)

# ## Materials
#
# Surfaces can be perfectly diffuse (matte), perfect mirrors, or glass
# (dielectric refractors).
enum ReflT
  Diffuse
  Specular
  Refractive
end

# ## The scene
#
# Spheres are the only primitive. Intersection is solved analytically: for a
# ray `o + t*d` we solve the quadratic for `t` and return the smallest
# positive hit beyond a small epsilon (which avoids "shadow acne" from
# self-intersection).
struct Sphere
  getter radius : Float64, position : Vec, emission : Vec, color : Vec, reflection : ReflT

  def initialize(@radius, @position, @emission, @color, @reflection)
  end

  def intersect(ray : Ray)
    op = position - ray.o
    epsilon = 1e-4
    b = op.dot(ray.d)
    det = b * b - op.dot(op) + radius * radius
    return 0.0 if det < 0
    det = Math.sqrt(det)
    t = b - det
    return t if t > epsilon
    t = b + det
    t > epsilon ? t : 0.0
  end
end

# The classic Cornell-box-like room: six huge spheres acting as walls (red and
# blue side walls, grey floor and ceiling), a mirror sphere, a glass sphere,
# and a big emissive sphere as the only light source.
SPHERES = [
  Sphere.new(1e5, Vec.new(1e5 + 1, 40.8, 81.6), Vec.new, Vec.new(0.75, 0.25, 0.25), ReflT::Diffuse),   # Left
  Sphere.new(1e5, Vec.new(-1e5 + 99, 40.8, 81.6), Vec.new, Vec.new(0.25, 0.25, 0.75), ReflT::Diffuse), # Right
  Sphere.new(1e5, Vec.new(50, 40.8, 1e5), Vec.new, Vec.new(0.75, 0.75, 0.75), ReflT::Diffuse),         # Back
  Sphere.new(1e5, Vec.new(50, 40.8, -1e5 + 170), Vec.new, Vec.new, ReflT::Diffuse),                    # Front
  Sphere.new(1e5, Vec.new(50, 1e5, 81.6), Vec.new, Vec.new(0.75, 0.75, 0.75), ReflT::Diffuse),         # Bottom
  Sphere.new(1e5, Vec.new(50, -1e5 + 81.6, 81.6), Vec.new, Vec.new(0.75, 0.75, 0.75), ReflT::Diffuse), # Top
  Sphere.new(16.5, Vec.new(27, 16.5, 47), Vec.new, Vec.new(1, 1, 1) * 0.999, ReflT::Specular),         # Mirror
  Sphere.new(16.5, Vec.new(73, 16.5, 78), Vec.new, Vec.new(1, 1, 1) * 0.999, ReflT::Refractive),       # Glass
  Sphere.new(600, Vec.new(50, 681.6 - 0.27, 81.6), Vec.new(12, 12, 12), Vec.new, ReflT::Diffuse),      # Light
]

# ## Small utilities
#
# Color channels are clamped to `[0, 1]`, then gamma-corrected (`2.2` gamma)
# for display.
def clamp(value : Float64)
  value < 0 ? 0.0 : value > 1 ? 1.0 : value
end

def to_int(value : Float64)
  (clamp(value) ** (1 / 2.2) * 255 + 0.5).to_i
end

# Scene intersection: linear scan over all spheres, keeping the closest hit.
# We iterate backwards so ties resolve exactly like the C++ original does.
def intersect(ray : Ray)
  t = 1e20
  id = 0
  SPHERES.size.downto(1) do |index|
    distance = SPHERES[index - 1].intersect(ray)
    next unless distance != 0.0 && distance < t
    t = distance
    id = index - 1
  end
  {t < 1e20, t, id}
end

# Random numbers: each scanline gets its own PCG32 stream seeded from the row
# index, so output is deterministic regardless of thread scheduling. `next_u`
# yields a UInt32, which we map uniformly onto `[0, 1)`.
TWO_POW_32_INV = 1.0 / 4294967296.0

def next_f(rng : Random::PCG32) : Float64
  rng.next_u * TWO_POW_32_INV
end

# ## The heart: radiance estimation
#
# `radiance` traces a ray and returns the light it carries. At every bounce it
# picks up the surface's emission, then recurses along a randomly chosen
# direction depending on the material.
#
# **Russian roulette**: after 5 bounces, paths are killed with probability
# `1 - p`, where `p` is the brightest color channel. Surviving paths are
# scaled by `1/p` so the estimate stays unbiased — expected contribution is
# unchanged, but deep paths terminate quickly.
def radiance(ray : Ray, depth : Int32, rng : Random::PCG32) : Vec
  hit, t, sphere_index = intersect(ray)
  return Vec.new unless hit

  object = SPHERES[sphere_index]
  x = ray.o + ray.d * t                # hit point
  n = (x - object.position).norm       # geometric normal
  nl = n.dot(ray.d) < 0 ? n : n * -1.0 # normal facing the incoming ray
  f = object.color
  p = f.x > f.y && f.x > f.z ? f.x : f.y > f.z ? f.y : f.z

  depth += 1
  if depth > 5
    if next_f(rng) < p
      f = f * (1 / p)
    else
      return object.emission
    end
  end

  case object.reflection
  in .diffuse?
    # Diffuse: sample the cosine-weighted hemisphere around the normal. The
    # tangent-frame construction (`w`, `u`, `v`) is the standard branchless
    # trick: pick any vector not parallel to the normal, build an orthonormal
    # basis, and express the sampled direction in it.
    r1 = 2 * Math::PI * next_f(rng)
    r2 = next_f(rng)
    r2s = Math.sqrt(r2)
    w = nl
    u = ((w.x.abs > 0.1 ? Vec.new(0, 1, 0) : Vec.new(1, 0, 0)) % w).norm
    v = w % u
    d = (u * (Math.cos(r1) * r2s) + v * (Math.sin(r1) * r2s) + w * Math.sqrt(1 - r2)).norm
    object.emission + f.mult(radiance(Ray.new(x, d), depth, rng))
  in .specular?
    # Perfect mirror: reflect the ray about the normal and keep going.
    object.emission + f.mult(radiance(Ray.new(x, ray.d - n * (2 * n.dot(ray.d))), depth, rng))
  in .refractive?
    radiance_refractive(object, ray, x, n, nl, f, depth, rng)
  end
end

# Glass is the subtle case. The ray may refract (bend) into or out of the
# sphere, or reflect — governed by Fresnel's equations:
#
# * If total internal reflection occurs (`cos2t < 0`), the ray *must* reflect.
# * Otherwise both reflection and refraction are possible. Below 2 bounces we
#   add both contributions weighted by Fresnel reflectance `Re`; deeper, we
#   pick one at random with probability proportional to its weight (Russian
#   roulette again), which keeps the estimator unbiased while cutting cost.
def radiance_refractive(object : Sphere, ray : Ray, x : Vec, n : Vec, nl : Vec,
                        f : Vec, depth : Int32, rng : Random::PCG32) : Vec
  refl_ray = Ray.new(x, ray.d - n * (2 * n.dot(ray.d)))
  into = n.dot(nl) > 0 # entering or exiting the glass?
  nc = 1.0             # index of refraction of air
  nt = 1.5             # index of refraction of glass
  nnt = into ? nc / nt : nt / nc
  ddn = ray.d.dot(nl)
  cos2t = 1 - nnt * nnt * (1 - ddn * ddn)
  return object.emission + f.mult(radiance(refl_ray, depth, rng)) if cos2t < 0

  tdir = (ray.d * nnt - n * ((into ? 1.0 : -1.0) * (ddn * nnt + Math.sqrt(cos2t)))).norm
  a = nt - nc
  b = nt + nc
  r0 = a * a / (b * b) # Fresnel reflectance at normal incidence
  c = 1 - (into ? -ddn : tdir.dot(n))
  re = r0 + (1 - r0) * c * c * c * c * c # Schlick's approximation
  tr = 1 - re
  prob = 0.25 + 0.5 * re
  rp = re / prob
  tp = tr / (1 - prob)
  object.emission +
    f.mult(
      if depth > 2
        if next_f(rng) < prob
          radiance(refl_ray, depth, rng) * rp
        else
          radiance(Ray.new(x, tdir), depth, rng) * tp
        end
      else
        radiance(refl_ray, depth, rng) * re + radiance(Ray.new(x, tdir), depth, rng) * tr
      end
    )
end

# ## Camera setup
#
# A pinhole camera looking down `-Z`. `cx` and `cy` are the horizontal and
# vertical increments per pixel; the odd-looking `-0.042612` tilt gives the
# scene its slightly elevated viewpoint.
width = 1024
height = 768
samples : Int32 = ARGV.size == 1 ? (ARGV[0].to_i // 4) : 1

camera = Ray.new(Vec.new(50, 52, 295.6), Vec.new(0, -0.042612, -1).norm)
cx = Vec.new(width * 0.5135 / height)
cy = (cx % camera.d).norm * 0.5135

canvas = Slice(Vec).new(width * height, Vec.new)

# ## Parallel rendering
#
# Since Crystal 1.21 programs start with parallelism set to 1, so we resize
# the default execution context to use every core.
#
# Rows are claimed from a shared atomic counter (work stealing): no worker
# ever touches another's pixels, so there is no locking on the canvas, and
# scaling is near-perfect. Each row seeds its own RNG stream, so results are
# reproducible no matter which worker gets which row.
start_time = Time.instant

workers = System.cpu_count
Fiber::ExecutionContext.default.resize(workers)
next_row = Atomic(Int32).new(0)
done_rows = Atomic(Int32).new(0)
wg = WaitGroup.new(workers)

workers.times do
  spawn do
    loop do
      y = next_row.add(1)
      break if y >= height
      render_row(y, width, height, samples, camera, cx, cy, canvas)
      done = done_rows.add(1) + 1
      STDERR.printf("\rRendering (%d spp) %5.2f%%", samples * 4, 100.0 * done / height) if done % 16 == 0
    end
    wg.done
  end
end

wg.wait

elapsed = Time.instant - start_time
STDERR.puts "\rRendering took #{elapsed.total_milliseconds / 1000.0}s   "

File.write("image.ppm", build_string(canvas, width, height))

# Rendering one scanline: for each pixel we take a 2x2 grid of subpixels, and
# for each subpixel average `samples` camera rays. Rays are jittered inside
# the subpixel with a **tent filter** (the `dx`/`dy` computation concentrates
# samples toward the subpixel center), which reduces aliasing better than
# uniform jitter.
def render_row(y : Int32, width : Int32, height : Int32, samples : Int32,
               camera : Ray, cx : Vec, cy : Vec, canvas : Slice(Vec))
  rng = Random::PCG32.new(UInt64.new(y * y * y))
  width.times do |x|
    2.times do |subpixel_y|
      index = (height - y - 1) * width + x
      2.times do |subpixel_x|
        accumulated = Vec.new
        samples.times do
          r1 = 2 * next_f(rng)
          dx = r1 < 1 ? Math.sqrt(r1) - 1 : 1 - Math.sqrt(2 - r1)
          r2 = 2 * next_f(rng)
          dy = r2 < 1 ? Math.sqrt(r2) - 1 : 1 - Math.sqrt(2 - r2)
          direction = cx * (((subpixel_x + 0.5 + dx) / 2 + x) / width - 0.5) +
                      cy * (((subpixel_y + 0.5 + dy) / 2 + y) / height - 0.5) +
                      camera.d
          accumulated += radiance(Ray.new(camera.o + direction * 140, direction.norm), 0, rng) * (1.0 / samples)
        end
        canvas[index] += Vec.new(clamp(accumulated.x), clamp(accumulated.y), clamp(accumulated.z)) * 0.25
      end
    end
  end
end

# Finally, write the image out as ASCII PPM (the format that requires zero
# dependencies to produce).
def build_string(canvas : Slice(Vec), width : Int32, height : Int32)
  String.build do |io|
    io << "P3\n#{width} #{height}\n255\n"
    canvas.each do |pixel|
      io << to_int(pixel.x) << ' ' << to_int(pixel.y) << ' ' << to_int(pixel.z) << ' '
    end
  end
end
