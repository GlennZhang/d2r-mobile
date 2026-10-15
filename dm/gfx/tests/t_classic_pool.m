#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
int main(void) { @autoreleasepool {
    mtl_init(); g_m4 = 0; g_classic_pool_ranges = 1;
    size_t size = 64 << 20; uint8_t *mem;
    if (posix_memalign((void **)&mem, getpagesize(), size)) return 1;
    for (size_t i = 0; i < size; i++) mem[i] = (uint8_t)(i ^ (i >> 8));
    mtl_pool_add(mem, size);
    uintptr_t edge = ((uintptr_t)mem + (2 << 20)) & ~((uintptr_t)(1 << 20) - 1);
    uint8_t *src = (uint8_t *)(edge - 32768); void *obj; uint64_t off, gpu;
    if (!mtl_gpu_addr((uint64_t)src, 65536, &obj, &off, &gpu)) return 2;
    id<MTLBuffer> in = (__bridge id<MTLBuffer>)obj;
    if (in.length > (2 << 20) || gpu != in.gpuAddress + off) return 3;
    id<MTLBuffer> out = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromBuffer:in sourceOffset:off toBuffer:out destinationOffset:0 size:65536]; [bl endEncoding];
    res_commit(); [cb commit]; [cb waitUntilCompleted];
    if (cb.error || memcmp(src, out.contents, 65536)) return 4;
    if (mtl_addr((uint64_t)mem + size - 8, 16, &obj, &off)) return 5;
    NSError *error = nil;
    NSString *msl = @"#include <metal_stdlib>\nusing namespace metal; struct Args { device ulong *table [[id(0)]]; }; kernel void probe(constant Args &a [[buffer(0)]], device uint *out [[buffer(1)]]) { device uint *p = reinterpret_cast<device uint *>(a.table[0x310/8]); out[0] = p[0]; }";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:msl options:nil error:&error];
    id<MTLFunction> fn = [lib newFunctionWithName:@"probe"];
    id<MTLComputePipelineState> ps = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&error] : nil;
    if (!ps) { fprintf(stderr, "%s\n", error.description.UTF8String); return 7; }
    NvShader *sh = [NvShader new]; sh->fn = fn; sh->ae = [fn newArgumentEncoderWithBufferIndex:0]; sh->arg_len = sh->ae.encodedLength;
    sh->rf.nb = 1; sh->rf.abi = 0; sh->rf.b[0].kind = NVN_RB_DRV0; sh->rf.b[0].aid = 0; sh->rf.drv_read[0] = 1;
    S.ssbo[5][0] = (p_bind_buf){.addr=(uint64_t)src, .size=65536};
    arena_begin(); cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; encode_args(ce, sh, 5, 0); [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [ce endEncoding];
    res_commit(); [cb commit]; [cb waitUntilCompleted];
    if (cb.error || memcmp(src, out.contents, 4)) return 8;
    puts("CLASSIC_POOL_GPU indirect-driver-pointer PASS");
    mtl_pool_del(mem); if (mtl_addr((uint64_t)src, 65536, &obj, &off)) return 6;
    printf("CLASSIC_POOL_GPU cross-window bytes=65536 buffer=%lu pool=%lu PASS\n", (unsigned long)in.length, (unsigned long)size);
    free(mem);
    // The selective experiment must keep small pools fully mapped.
    g_classic_pool_ranges = 2;
    if (posix_memalign((void **)&mem, getpagesize(), size)) return 9;
    mtl_pool_add(mem, size);
    pool_ent *pool = &g_pools[g_npool - 1];
    if (pool->resident || [g_res_objects containsObject:pool->buf]) return 14;
    if (!mtl_addr((uint64_t)mem, 4, &obj, &off) || ((__bridge id<MTLBuffer>)obj).length != size) return 10;
    if (!pool->resident || ![g_res_objects containsObject:pool->buf] || g_res_dirty) return 15;
    mtl_pool_del(mem); free(mem);
    size = 512ull << 20;
    if (posix_memalign((void **)&mem, getpagesize(), size)) return 11;
    memcpy(mem, "pool", 4); mtl_pool_add(mem, size);
    if (!mtl_addr((uint64_t)mem, 4, &obj, &off) || ((__bridge id<MTLBuffer>)obj).length > (1 << 20)) return 12;
    in = (__bridge id<MTLBuffer>)obj;
    cb = [g_q commandBuffer]; bl = [cb blitCommandEncoder];
    [bl copyFromBuffer:in sourceOffset:off toBuffer:out destinationOffset:0 size:4]; [bl endEncoding];
    res_commit(); [cb commit]; [cb waitUntilCompleted];
    if (cb.error || memcmp(out.contents, "pool", 4)) return 13;
    mtl_pool_del(mem); free(mem);
    puts("CLASSIC_POOL_GPU selective-small-full-large-range PASS");
    return 0;
}}
