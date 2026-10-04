"""Renders Peek's two static UI plates with headless Blender (run by render_ui.sh).

  artwork-light.png / artwork-dark.png  256×256  machined aluminium puck, blue waveform inlay
  meter-plate-dark.png / -light.png     160×320  anodized recessed panel, 9-slice (cap 28 px)

Everything is baked once into small PNGs; the preview only draws images.
"""
import math, sys, os
import bpy

out = sys.argv[sys.argv.index("--") + 1]
os.makedirs(out, exist_ok=True)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    s = bpy.context.scene
    try:
        s.render.engine = "CYCLES"
    except TypeError:
        pass
    s.cycles.samples = 96
    s.cycles.use_denoising = True
    s.render.film_transparent = True
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_mode = "RGBA"
    s.view_settings.view_transform = "Standard"
    return s


def principled(name, color, metallic, rough, aniso=0.0, emission=None, strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if "Anisotropic" in b.inputs:
        b.inputs["Anisotropic"].default_value = aniso
    if emission is not None:
        b.inputs["Emission Color"].default_value = (*emission, 1)
        b.inputs["Emission Strength"].default_value = strength
    return m


def area(name, loc, rot, energy, size):
    bpy.ops.object.light_add(type="AREA", location=loc, rotation=rot)
    l = bpy.context.object
    l.name = name
    l.data.energy = energy
    l.data.size = size
    return l


def camera(loc, rot, ortho):
    bpy.ops.object.camera_add(location=loc, rotation=rot)
    c = bpy.context.object
    c.data.type = "ORTHO"
    c.data.ortho_scale = ortho
    bpy.context.scene.camera = c


def world(strength):
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    bg = next(n for n in w.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Strength"].default_value = strength
    bg.inputs["Color"].default_value = (0.6, 0.62, 0.66, 1)
    bpy.context.scene.world = w


def puck(dark):
    s = reset()
    world(0.35 if dark else 0.6)
    s.render.resolution_x = s.render.resolution_y = 256
    body_color = (0.16, 0.17, 0.19) if dark else (0.78, 0.79, 0.81)
    bpy.ops.mesh.primitive_cylinder_add(vertices=128, radius=1.0, depth=0.28, location=(0, 0, 0))
    disc = bpy.context.object
    mod = disc.modifiers.new("bevel", "BEVEL")
    mod.width = 0.06
    mod.segments = 6
    bpy.ops.object.shade_smooth()
    disc.data.materials.append(principled("alu", body_color, 1.0, 0.32, aniso=0.6))
    # Waveform inlay: rounded bars sunk into the face, lit from inside.
    inlay = principled("inlay", (0.02, 0.18, 0.85), 0.0, 0.3, emission=(0.02, 0.2, 1.0), strength=0.9 if dark else 0.45)
    heights = [0.18, 0.34, 0.55, 0.8, 0.52, 0.95, 0.62, 0.38, 0.7, 0.44, 0.24]
    for i, h in enumerate(heights):
        x = (i - (len(heights) - 1) / 2) * 0.13
        bpy.ops.mesh.primitive_cube_add(size=1, location=(x, 0, 0.13))
        bar = bpy.context.object
        bar.scale = (0.05, 0.5 * h * 0.95, 0.03)
        bv = bar.modifiers.new("bevel", "BEVEL")
        bv.width = 0.015
        bv.segments = 4
        bar.data.materials.append(inlay)
    area("key", (-2.2, -2.4, 3.2), (math.radians(40), 0, math.radians(-40)), 350 if dark else 420, 2.4)
    area("rim", (2.6, 2.0, 1.6), (math.radians(60), 0, math.radians(130)), 180, 2.0)
    camera((0, -2.6, 3.6), (math.radians(36), 0, 0), 2.12)
    s.render.filepath = os.path.join(out, f"artwork-{'dark' if dark else 'light'}.png")
    bpy.ops.render.render(write_still=True)


def plate(dark):
    s = reset()
    world(0.3 if dark else 0.35)
    s.render.resolution_x, s.render.resolution_y = 160, 320
    s.cycles.samples = 64
    base = (0.07, 0.075, 0.085) if dark else (0.72, 0.73, 0.75)
    # Outer rim and a recessed floor: reads as a machined tray behind the meters.
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    rim = bpy.context.object
    rim.scale = (1.0, 2.0, 0.08)
    b = rim.modifiers.new("bevel", "BEVEL"); b.width = 0.06; b.segments = 5
    rim.data.materials.append(principled("rim", base, 0.9, 0.35, aniso=0.4))
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0.012))
    floor = bpy.context.object
    floor.scale = (0.86, 1.86, 0.08)
    b = floor.modifiers.new("bevel", "BEVEL"); b.width = 0.03; b.segments = 4
    floor_color = tuple(c * (0.55 if dark else 0.93) for c in base)
    floor.data.materials.append(principled("floor", floor_color, 0.2, 0.7))
    bool_mod = rim.modifiers.new("cut", "BOOLEAN"); bool_mod.object = floor; bool_mod.operation = "DIFFERENCE"
    floor.location.z = 0.03
    floor2 = floor.copy(); floor2.data = floor.data.copy(); floor2.location.z = -0.01
    bpy.context.collection.objects.link(floor2)
    floor.hide_render = True
    area("key", (-1.0, -1.6, 3.0), (math.radians(28), 0, math.radians(-20)), 90 if dark else 45, 2.5)
    camera((0, 0, 4), (0, 0, 0), 2.0)
    s.render.filepath = os.path.join(out, f"meter-plate-{'dark' if dark else 'light'}.png")
    bpy.ops.render.render(write_still=True)


for d in (False, True):
    puck(d)
    plate(d)
print("RENDER DONE", out)
