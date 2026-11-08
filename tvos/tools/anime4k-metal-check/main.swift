// Runs the generated Anime4K Metal kernels on a raw RGBA float32 image so CI
// can compare them with tools/anime4k_reference.py.
// usage: anime4k-metal-check <kernels.metal> <shader,shader> <in.f32> <width> <height> <out.f32>
import Foundation
import Metal

let args = CommandLine.arguments
guard args.count == 7, let width = Int(args[4]), let height = Int(args[5]) else {
    FileHandle.standardError.write("usage: anime4k-metal-check <kernels.metal> <shaders> <in.f32> <w> <h> <out.f32>\n".data(using: .utf8)!)
    exit(2)
}
guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP: no Metal device")
    exit(0)
}
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let start = Date()
let library = try device.makeLibrary(source: source, options: nil)
print(String(format: "compiled kernels in %.1fs on %@", Date().timeIntervalSince(start), device.name))

let shaders = args[2].split(separator: ",").map(String.init)
var pixels = [Float](repeating: 0, count: width * height * 4)
let data = try Data(contentsOf: URL(fileURLWithPath: args[3]))
precondition(data.count == pixels.count * 4, "input size mismatch")
_ = pixels.withUnsafeMutableBytes { data.copyBytes(to: $0) }

let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
desc.usage = [.shaderRead]
desc.storageMode = .shared
let input = device.makeTexture(descriptor: desc)!
input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 16)

let processor = Anime4KProcessor(device: device, library: library, storageMode: .shared)
try processor.prepare(shaders)
let queue = device.makeCommandQueue()!
let cb = queue.makeCommandBuffer()!
let out = try processor.encode(shaders, input: input, commandBuffer: cb)
cb.commit()
cb.waitUntilCompleted()
if let error = cb.error { fatalError("GPU error: \(error)") }
print(String(format: "GPU time %.2f ms for %dx%d -> %dx%d", (cb.gpuEndTime - cb.gpuStartTime) * 1000, width, height, out.width, out.height))

var half = [Float16](repeating: 0, count: out.width * out.height * 4)
out.getBytes(&half, bytesPerRow: out.width * 8, from: MTLRegionMake2D(0, 0, out.width, out.height), mipmapLevel: 0)
let result = half.map { Float($0) }
try result.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: args[6])) }
