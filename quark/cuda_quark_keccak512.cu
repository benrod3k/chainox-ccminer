#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>
#include <memory.h>

// Folgende Definitionen sp㳥r durch header ersetzen
typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
//typedef unsigned long long uint64_t;

// aus heavy.cu
extern cudaError_t MyStreamSynchronize(cudaStream_t stream, int situation, int thr_id);

#include "cuda_helper.h"

#define U32TO64_LE(p) \
    (((uint64_t)(*p)) | (((uint64_t)(*(p + 1))) << 32))

#define U64TO32_LE(p, v) \
    *p = (uint32_t)((v)); *(p+1) = (uint32_t)((v) >> 32);

static const uint64_t host_keccak_round_constants[24] = {
    0x0000000000000001ull, 0x0000000000008082ull,
    0x800000000000808aull, 0x8000000080008000ull,
    0x000000000000808bull, 0x0000000080000001ull,
    0x8000000080008081ull, 0x8000000000008009ull,
    0x000000000000008aull, 0x0000000000000088ull,
    0x0000000080008009ull, 0x000000008000000aull,
    0x000000008000808bull, 0x800000000000008bull,
    0x8000000000008089ull, 0x8000000000008003ull,
    0x8000000000008002ull, 0x8000000000000080ull,
    0x000000000000800aull, 0x800000008000000aull,
    0x8000000080008081ull, 0x8000000000008080ull,
    0x0000000080000001ull, 0x8000000080008008ull
};

__constant__ uint64_t c_keccak_round_constants[24];

static __device__ __forceinline__ void
keccak_block(uint64_t *s, const uint32_t *in, const uint64_t *keccak_round_constants) {
    size_t i;
    uint64_t t[5], u[5], v, w;

    /* absorb input */
#pragma unroll 9
    for (i = 0; i < 72 / 8; i++, in += 2)
        s[i] ^= U32TO64_LE(in);
    
    for (i = 0; i < 24; i++) {
        /* theta: c = a[0,i] ^ a[1,i] ^ .. a[4,i] */
        t[0] = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
        t[1] = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
        t[2] = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
        t[3] = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
        t[4] = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];

        /* theta: d[i] = c[i+4] ^ rotl(c[i+1],1) */
        u[0] = t[4] ^ ROTL64(t[1], 1);
        u[1] = t[0] ^ ROTL64(t[2], 1);
        u[2] = t[1] ^ ROTL64(t[3], 1);
        u[3] = t[2] ^ ROTL64(t[4], 1);
        u[4] = t[3] ^ ROTL64(t[0], 1);

        /* theta: a[0,i], a[1,i], .. a[4,i] ^= d[i] */
        s[0] ^= u[0]; s[5] ^= u[0]; s[10] ^= u[0]; s[15] ^= u[0]; s[20] ^= u[0];
        s[1] ^= u[1]; s[6] ^= u[1]; s[11] ^= u[1]; s[16] ^= u[1]; s[21] ^= u[1];
        s[2] ^= u[2]; s[7] ^= u[2]; s[12] ^= u[2]; s[17] ^= u[2]; s[22] ^= u[2];
        s[3] ^= u[3]; s[8] ^= u[3]; s[13] ^= u[3]; s[18] ^= u[3]; s[23] ^= u[3];
        s[4] ^= u[4]; s[9] ^= u[4]; s[14] ^= u[4]; s[19] ^= u[4]; s[24] ^= u[4];

        /* rho pi: b[..] = rotl(a[..], ..) */
        v = s[ 1];
        s[ 1] = ROTL64(s[ 6], 44);
        s[ 6] = ROTL64(s[ 9], 20);
        s[ 9] = ROTL64(s[22], 61);
        s[22] = ROTL64(s[14], 39);
        s[14] = ROTL64(s[20], 18);
        s[20] = ROTL64(s[ 2], 62);
        s[ 2] = ROTL64(s[12], 43);
        s[12] = ROTL64(s[13], 25);
        s[13] = ROTL64(s[19],  8);
        s[19] = ROTL64(s[23], 56);
        s[23] = ROTL64(s[15], 41);
        s[15] = ROTL64(s[ 4], 27);
        s[ 4] = ROTL64(s[24], 14);
        s[24] = ROTL64(s[21],  2);
        s[21] = ROTL64(s[ 8], 55);
        s[ 8] = ROTL64(s[16], 45);
        s[16] = ROTL64(s[ 5], 36);
        s[ 5] = ROTL64(s[ 3], 28);
        s[ 3] = ROTL64(s[18], 21);
        s[18] = ROTL64(s[17], 15);
        s[17] = ROTL64(s[11], 10);
        s[11] = ROTL64(s[ 7],  6);
        s[ 7] = ROTL64(s[10],  3);
        s[10] = ROTL64(    v,  1);

        /* chi: a[i,j] ^= ~b[i,j+1] & b[i,j+2] */
        v = s[ 0]; w = s[ 1]; s[ 0] ^= (~w) & s[ 2]; s[ 1] ^= (~s[ 2]) & s[ 3]; s[ 2] ^= (~s[ 3]) & s[ 4]; s[ 3] ^= (~s[ 4]) & v; s[ 4] ^= (~v) & w;
        v = s[ 5]; w = s[ 6]; s[ 5] ^= (~w) & s[ 7]; s[ 6] ^= (~s[ 7]) & s[ 8]; s[ 7] ^= (~s[ 8]) & s[ 9]; s[ 8] ^= (~s[ 9]) & v; s[ 9] ^= (~v) & w;
        v = s[10]; w = s[11]; s[10] ^= (~w) & s[12]; s[11] ^= (~s[12]) & s[13]; s[12] ^= (~s[13]) & s[14]; s[13] ^= (~s[14]) & v; s[14] ^= (~v) & w;
        v = s[15]; w = s[16]; s[15] ^= (~w) & s[17]; s[16] ^= (~s[17]) & s[18]; s[17] ^= (~s[18]) & s[19]; s[18] ^= (~s[19]) & v; s[19] ^= (~v) & w;
        v = s[20]; w = s[21]; s[20] ^= (~w) & s[22]; s[21] ^= (~s[22]) & s[23]; s[22] ^= (~s[23]) & s[24]; s[23] ^= (~s[24]) & v; s[24] ^= (~v) & w;

        /* iota: a[0,0] ^= round constant */
        s[0] ^= keccak_round_constants[i];
    }
}

__global__ void quark_keccak512_gpu_hash_64(int threads, uint32_t startNounce, uint64_t *g_hash, uint32_t *g_nonceVector)
{
    int thread = (blockDim.x * blockIdx.x + threadIdx.x);
    if (thread < threads)
    {
        uint32_t nounce = (g_nonceVector != NULL) ? g_nonceVector[thread] : (startNounce + thread);

        int hashPosition = nounce - startNounce;
        uint32_t *inpHash = (uint32_t*)&g_hash[8 * hashPosition];

        // Nachricht kopieren
        uint32_t message[18];
#pragma unroll 16
        for(int i=0;i<16;i++)
            message[i] = inpHash[i];

        message[16] = 0x01;
        message[17] = 0x80000000;

        // State initialisieren
        uint64_t keccak_gpu_state[25];
#pragma unroll 25
        for (int i=0; i<25; i++)
            keccak_gpu_state[i] = 0;

        // den Block einmal gut durchschtteln
        keccak_block(keccak_gpu_state, message, c_keccak_round_constants);

        // das Hash erzeugen
        uint32_t hash[16];

#pragma unroll 8
        for (size_t i = 0; i < 64; i += 8) {
            U64TO32_LE((&hash[i/4]), keccak_gpu_state[i / 8]);
        }

        // fertig
        uint32_t *outpHash = (uint32_t*)&g_hash[8 * hashPosition];

#pragma unroll 16
        for(int i=0;i<16;i++)
            outpHash[i] = hash[i];
    }
}

// Setup-Funktionen
__host__ void quark_keccak512_cpu_init(int thr_id, int threads)
{
    // Kopiere die Hash-Tabellen in den GPU-Speicher
    cudaMemcpyToSymbol( c_keccak_round_constants,
                        host_keccak_round_constants,
                        sizeof(host_keccak_round_constants),
                        0, cudaMemcpyHostToDevice);
}

__host__ void quark_keccak512_cpu_hash_64(int thr_id, int threads, uint32_t startNounce, uint32_t *d_nonceVector, uint32_t *d_hash, int order)
{
    const int threadsperblock = 256;

    // berechne wie viele Thread Blocks wir brauchen
    dim3 grid((threads + threadsperblock-1)/threadsperblock);
    dim3 block(threadsperblock);

    // Gr������des dynamischen Shared Memory Bereichs
    size_t shared_size = 0;

    quark_keccak512_gpu_hash_64<<<grid, block, shared_size>>>(threads, startNounce, (uint64_t*)d_hash, d_nonceVector);
    MyStreamSynchronize(NULL, order, thr_id);
}
