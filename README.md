# VRMKit

A small Swift library for VRM 1.0 avatars, glTF documents, and RealityKit rendering.

Two modules. No external dependencies.

| Module | Purpose | Platforms |
| --- | --- | --- |
| `VRMKit` | Loading, editing, geometry, poses, expressions, animation, and spring simulation | Swift 6; Foundation and standard Swift SIMD |
| `VRMRealityKit` | RealityKit entities, textures, materials, and frame updates | iOS 18+, macOS 15+, visionOS 2+ |

VRM 1.0 is the only avatar format supported. The core module does not import RealityKit, Metal, UIKit, AppKit, or Apple's `simd` module.

## Installation

Add this package to your Swift Package Manager dependencies:

```swift
.package(url: "https://github.com/meow2149/VRMKit.git", branch: "main")
```

Add `VRMKit` to a core target, or `VRMRealityKit` and `VRMKit` to an Apple rendering target. For a local checkout:

```swift
.package(path: "../VRMKit")
```

## Load an avatar

```swift
import Foundation
import VRMKit

let avatar = try Avatar(url: URL(fileURLWithPath: "/models/avatar.vrm"))
print(avatar.metadata.name)
print(avatar.metadata.authors)
let hips = avatar.node(for: .hips)
let thumbnail: Data? = try avatar.thumbnail()
```

`Avatar(document:)` and `Avatar(data:baseURL:)` accept an existing document or bytes. An avatar exposes humanoid bones, expressions, first-person annotations, look-at settings, colliders, and springs. Original metadata and permission fields are available through `metadata.raw`.

## Render with RealityKit

```swift
import Foundation
import RealityKit
import VRMKit
import VRMRealityKit

let model = try await Loader.load(url: avatarURL)
anchor.addChild(model)

try model.instance.setExpression("happy", weight: 0.8)
model.look(at: SIMD3<Float>(0, 1.5, 2))
```

Create an anchor and add it to your RealityKit scene as usual. The loader installs a frame update system automatically. `Loader` also accepts `Data` or a `Document`, and can render a plain glTF scene. Pass `scene:` when a document has no default scene.

Each load creates independent runtime state. Use another load to create another animated character. RealityKit's generic entity cloning does not copy runtime bindings.

To control timing yourself:

```swift
model.automaticUpdates = false
try model.update(deltaTime: 1 / 60)
```

An automatic update failure is stored in `lastError`, calls `onError` if installed, and disables automatic updates. Manual updates throw errors directly. With automatic updates disabled, the scene system refreshes lighting and shadows without advancing the instance. For several manually driven avatars, use `try AvatarEntity.update([first, second], deltaTime: 1 / 60)` to evaluate their poses together before rendering shared shadows.

## Pose and expressions

```swift
let instance = try avatar.makeInstance()
try instance.setExpressions(["blink": 0.5, "aa": 0.3])

if let neck = avatar.node(for: .neck) {
    let rest = instance.pose.rest[neck].rotation
    try instance.pose.setRotation(
        rest * Quaternion(angle: .pi / 12, axis: SIMD3(0, 0, 1)),
        at: neck
    )
}

try instance.update(deltaTime: 1 / 60)
```

`Instance` combines expressions with animated morph weights and exposes the resulting `morphWeights`, `materials`, and `textureTransforms`. Expressions support binary weights, blink/mouth/look-at overrides, morph binds, material colors, and texture transforms. `resetExpressions()` clears explicit weights.

`onPose` runs after animation and before gaze, constraints, and springs. Use it for tracking or procedural posing. Renderer node edits are read back at the start of an update; `model.bone(.leftHand)` returns the corresponding RealityKit entity for attachments.

Runtime instances and playback controllers are mutable and belong to one thread. Document, avatar, animation, and geometry values are `Sendable`. Rendering APIs run on the main actor.

## Animation and gaze

```swift
let playback = try model.instance.play(0, loops: true)
playback.speed = 1.5
playback.seek(to: 0.4)
playback.isPaused = true

let motion = try Motion(url: URL(fileURLWithPath: "/models/walk.vrma"))
let motionPlayback = try model.instance.play(motion)
motionPlayback.speed = -1

model.instance.gaze = .angles(yaw: 15, pitch: 5)
model.instance.gaze = nil
```

glTF tracks support `STEP`, `LINEAR`, and `CUBICSPLINE` interpolation for translation, rotation, scale, and morph weights. VRM motion clips retarget humanoid rotations and hips movement, expressions, and gaze. Missing chest, upper-chest, neck, and shoulder bones use available neighboring humanoid bones.

Positive yaw looks toward positive X; positive pitch looks up. A `Gaze.position` is in instance coordinates. `AvatarEntity.look(at:)` converts a world-space point when called; call it again if the entity or target moves.

Multiple clips are applied in playback order, with later clips replacing channels they animate. There is no animation blending. Non-looping clips hold their final pose. Stopping a clip removes its future updates; it does not reset the pose or expression weights. Use `pose.reset()` and `resetExpressions()` when needed.

## Springs and first-person views

```swift
model.instance.springForce = SIMD3(0.2, 0, 0)
try model.instance.resetSprings()
model.isFirstPerson = true
```

Spring joints use a fixed 60 Hz simulation with inertia, stiffness, gravity, sphere/capsule collisions, and optional moving centers. Frame gaps are capped at 0.25 seconds. Reset springs after teleporting a character or replacing its pose.

First-person annotations control visibility. Automatic masking removes triangles influenced by the head or its descendants, and hides rigid meshes attached under the head. Switch `isFirstPerson` between updates.

## Read and edit documents

```swift
var document = avatar.document
try document.setAvatarName("My Avatar")
try document.setAvatarAuthors(["My Name"])

let item = try Document(url: itemURL)
let result = try document.merge(item, parent: avatar.node(for: .rightHand), name: "Accessory")
try document.convertMaterialsToToon(Array(result.materials))
try document.write(to: outputURL)
```

`Document` loads JSON `.gltf`, GLB, external buffers/images, and data URIs. Its mutable `root` is a JSON tree, so extension fields and extras remain accessible. `glb()` embeds standard buffers and images in one portable binary file; `write(to:)` saves atomically.

Use `entry(_:at:)`, `accessor(_:)`, `mesh(_:)`, `skin(_:)`, and `image(_:)` to read resources. Accessors support interleaved data, normalized integer components, sparse replacements, and padded matrix columns.

Editing methods add scenes, nodes, triangle meshes, float accessors, animations, sphere/capsule colliders, and springs. Node edits preserve indices. `moveNode` changes the local hierarchy without preserving the world transform. Detaching a node keeps its data and references in the document.

Merging copies a plain glTF scene's resources, skins, node constraints, and animations beneath a wrapper node. Unknown extensions are rejected during merge because their indices cannot be safely rebased. A VRM avatar is not a supported merge source.

Thumbnail editing accepts square PNG or JPEG data. PNG/JPEG dimensions can also be read with `ImageInfo(data:)`. Metadata helpers leave license and permission fields intact.

## Create a VRM motion

```swift
var clip = Document()
let bones = try clip.addMotionSkeleton(from: avatar)
if let hand = bones[.rightHand] {
    let rest = try Pose(document: clip).rest[hand].rotation
    let raised = rest * Quaternion(angle: .pi / 4, axis: SIMD3(0, 0, 1))
    let values = [rest.vector, raised.vector].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    let track = try AnimationTrack(node: hand, path: .rotation, times: [0, 1], values: values)
    try clip.addAnimation(Animation(name: "Wave", tracks: [track]))
}
try clip.write(to: motionURL)
```

Expression animation nodes encode weights in translation X. Declare them with `setMotionExpressions`. `setMotionLookNode` declares a gaze animation node.

## MToon materials

The iOS and macOS custom material path implements the `VRMC_materials_mtoon` 1.0 parameters:

| Feature | Behavior |
| --- | --- |
| Toon lighting | Lit/shade colors, shade multiply, shading shift texture and scale, toony boundary, GI equalization |
| Rim and matcap | Matcap factor/texture, parametric rim color/power/lift, rim multiply, lighting mix |
| Outlines | World-space meters or screen-height ratio, width multiply, outline color and full surface-lighting mix |
| UV animation | Scroll, rotation around the UV center, animation-mask blue channel |
| Texture coordinates | Independent authored UV sets and `KHR_texture_transform` for each slot, plus expression transforms |
| Sampling | Clamp, repeat, mirrored repeat, nearest/linear magnification and all six glTF minification filters |
| Color | Linear lighting and factors, sRGB color-image decoding, raw data channels, explicit mip levels |
| Normals | Authored/morphed/skinned tangents, mirrored UV handedness, derivative basis when tangents are absent, normal strength |
| Transparency | Opaque, cutout and blend modes, depth-writing transparency, queue offsets, surface/outline ordering |
| Shadows | Directional, spot and six-face point shadows, animated cutouts, 3×3 filtering, bias and strength controls |

All MToon texture slots are handled independently. Shading shift reads red, outline width reads green, and UV animation mask reads blue, so these channels can share an image. Matcap uses view-based coordinates and is not UV animated. Vertex colors are ignored for MToon, as specified by the format. MToon takes precedence over `KHR_materials_unlit`.

Material colors and transforms from expressions update the parameter texture. UV animation uses `Instance.elapsedTime`, so manual frame updates control its clock too. Surface meshes rebuild only when geometry, mesh mode or outline bounds change.

## Lighting and shadows

When `model.lights` is empty, the toon renderer reads enabled RealityKit directional, point and spot light entities if `options.sceneLighting` is enabled. If none are found, it uses `options.lightDirection` and `options.lightColor`. `lightDirection` points toward the light; `ToonLight.direction` describes emitted rays. Light and ambient colors are linear RGB.

```swift
model.lights = [
    ToonLight(color: SIMD3(1, 0.95, 0.9), direction: SIMD3(-0.3, -0.8, -0.5)),
    ToonLight(kind: .point, color: SIMD3(0.2, 0.3, 0.5),
              position: SIMD3(1, 2, 1), range: 4, castsShadow: false)
]
model.options.exposure = 1
model.environment = ToonEnvironment(ambient: SIMD3(repeating: 0.2))

// Supply an equirectangular environment image for directional diffuse lighting.
try model.setEnvironment(data: environmentData, intensity: 0.8, rotation: .pi / 4)
```

An explicit light list replaces automatic scene-light discovery. Scene light intensity is converted using `sceneLightIntensityScale`, defaulting to `0.001`; point and spot lights also account for their emission solid angle. Adjust this scale and exposure for your scene. This conversion does not guarantee identical brightness to RealityKit's native PBR pipeline.

`ToonEnvironment` accepts either nine diffuse spherical-harmonic coefficients or linear equirectangular pixels. `setEnvironment` decodes an image and projects it into those coefficients. RealityKit's private environment irradiance and native shadow maps are not read by the custom shader.

Avatars in the same scene cast shadows onto each other's toon surfaces after all poses have updated. The complete deformed avatar casts shadows even when first-person view hides its head. Opaque and masked materials cast shadows; depth-writing blend materials use a binary alpha threshold of `0.5`. Ordinary blend materials do not cast a binary shadow. Outline shells do not cast shadows.

Register external opaque props through `model.shadowOccluders` with their `Geometry` and a world-space `Matrix4`. Update the supplied transform when a prop moves. These props cast onto toon avatars; this API does not make a toon avatar's custom shadow map available to native scene materials.

Defaults allow 16 lights and 12 shadow faces at 512 pixels per face. Each directional or spot light uses one face; a point light uses six. Lights are considered in list order. Lights beyond `maximumLights` are omitted; a light that cannot fit all its shadow faces remains lit without a shadow. Set `shadows = false` to disable shadow passes. `shadowBias` uses projected depth, `shadowNormalBias` uses world units, and `shadowStrength` ranges from zero to one.

## Rendering controls and limits

The renderer orders materials by opaque, cutout, depth-writing blend, then ordinary blend queues, respecting MToon queue offsets. It sorts equal transparent queues from far to near using a RealityKit perspective camera or `model.cameraPosition`. Set the latter each frame for an AR camera. Sorting is per primitive and cannot resolve every overlap inside one transparent mesh.

World outlines retain the authored width, including under nonuniform avatar scaling. Screen outlines use the projection matrix to maintain a screen-height ratio. `outlineBoundsPadding`, defaulting to one local unit, expands mesh bounds for screen outlines. Increase it for very wide outlines or distant views so RealityKit does not cull the expanded shell. Bounds padding does not clamp shader width.

`maximumTextureDimension` and `maximumAtlasDimension` default to 16384. Oversized source images are downsampled, and resources that cannot fit the configured atlases throw an error. Increasing image limits raises memory use. Changing either limit, shadow resolution/face budget, or the light budget recreates rendering resources on the next update.

Non-MToon materials use native PBR or unlit materials with base, normal, emission, occlusion and metallic-roughness channels. Normal and occlusion strengths are baked for the native path. This fallback uses the primary material UV transform and RealityKit's default sampling; independent per-slot sampling is provided by the custom MToon path. On visionOS, MToon uses the native unlit fallback because RealityKit custom materials are unavailable, so custom toon lighting, outlines and custom shadows are omitted.

Skinning and morphing run on the CPU. The custom path expands triangle vertices to carry original UV-table indices; dense animated meshes and multiple shadow passes can be expensive. Static images remain separate from mutable material/light/shadow data, and frame uploads use a shared Metal queue without waiting for GPU completion. RealityKit still controls final output tone mapping.

Compressed geometry and texture extensions, glTF vertex colors in native materials, glTF cameras and punctual-light import, extended spring colliders/limits, and animation-pointer channels are outside the supported scope.

This repository was authored on Linux. No compilation or runtime verification has been performed. The Apple adapter requires an Apple SDK. Its Metal shader source is compiled at runtime when rendering resources are created; visual equivalence across engines and devices has not been verified.

## Layout

```text
Package.swift
Sources/
  VRMKit/         JSON, documents, avatar data, geometry, editing, and runtime
  VRMRealityKit/  Entities, materials, texture sampling, lighting, shadows, and one Metal shader
```

## License

[MIT](LICENSE).
