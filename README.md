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

An automatic update failure is stored in `lastError`, calls `onError` if installed, and disables automatic updates. Manual updates throw errors directly.

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

## Materials and rendering scope

The RealityKit adapter supports PBR and unlit materials, base/normal/emission/occlusion textures, and the glTF metallic-roughness texture's separate channels. The toon path uses authored shade colors, shade textures, rim factors, emission, alpha cutouts, and outline shells. Configure its explicit light through `RenderOptions` or `model.options`.

Toon rendering is an approximation, not a complete MToon implementation. Screen-coordinate outline width is approximate, and outline expansion is capped at 0.1 local units for mesh bounds. Matcap, rim/outline/shift textures, UV scrolling, render queues, and complete scene-light/shadow integration are not implemented. On visionOS, toon materials use the unlit fallback because custom materials are unavailable.

The adapter uses CPU skinning and morphing, and rebuilds a mesh resource only when its geometry changes. Animated dense avatars can be expensive. Toon parameter uploads are synchronous when material values change. This implementation prioritizes a small, readable rendering path over GPU deformation infrastructure.

The renderer uses one UV transform per material and rejects conflicting texture transforms. It uses default texture sampling, does not reproduce every authored sampler option or normal/occlusion strength, and does not render vertex colors, glTF cameras, or punctual lights. Compressed geometry, compressed texture extensions, extended spring colliders/limits, and animation-pointer channels are outside the supported scope.

This repository was authored on Linux. No compilation or runtime verification has been performed. The Apple adapter requires an Apple SDK, and its Metal shader source is compiled on device when toon materials are first loaded.

## Layout

```text
Package.swift
Sources/
  VRMKit/         JSON, documents, avatar data, geometry, editing, and runtime
  VRMRealityKit/  Loader, entities, materials, and one Metal shader
```

## License

[MIT](LICENSE).
