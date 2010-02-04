/*
 * Sample Program for CUDA 2.3
 * written by M.Saito (saito@math.sci.hiroshima-u.ac.jp)
 *
 * This sample uses texture reference.
 * The generation speed of PRNG using texture is faster than using
 * constant tabel on Geforce GTX 260.
 *
 * MTGP32-23209
 * This program generates 32-bit unsigned integers.
 * The period of generated integers is 2<sup>23209</sup>-1.
 * This also generates single precision floating point numbers.
 */
#define __STDC_FORMAT_MACROS 1
#define __STDC_CONSTANT_MACROS 1
#include <stdio.h>
#include <cutil.h>
#include <stdint.h>
#include <inttypes.h>
#include <errno.h>
#include <stdlib.h>
extern "C" {
#include "mtgp32-fast.h"
}
#define MEXP 23209
#define N 726
#define THREAD_NUM 256
#define LARGE_SIZE (THREAD_NUM * 4)
#define BLOCK_NUM (27 * 3)
#define BLOCK_NUM_MAX 128
#define TBL_SIZE 16

/**
 * kernel I/O
 * This structure must be initialized before first use.
 */
struct mtgp32_kernel_status_t {
    uint32_t status[N];
};

texture<uint32_t, 1, cudaReadModeElementType> tex_param_ref;
texture<uint32_t, 1, cudaReadModeElementType> tex_temper_ref;
texture<uint32_t, 1, cudaReadModeElementType> tex_single_ref;
/*
 * Generator Parameters.
 */
__constant__ uint32_t pos_tbl[BLOCK_NUM_MAX];
__constant__ uint32_t sh1_tbl[BLOCK_NUM_MAX];
__constant__ uint32_t sh2_tbl[BLOCK_NUM_MAX];
/* high_mask and low_mask should be set by make_constant(), but
 * did not work.
 */
__constant__ uint32_t mask = 0xff800000;

/**
 * Shared memory
 * The generator's internal status vector.
 */
__shared__ uint32_t status[LARGE_SIZE]; /* 512 * 3 elements, 6144 bytes. */

/**
 * The function of the recursion formula calculation.
 *
 * @param[in] X1 the farthest part of state array.
 * @param[in] X2 the second farthest part of state array.
 * @param[in] Y a part of state array.
 * @param[in] bid block id.
 * @return output
 */
__device__ uint32_t para_rec(uint32_t X1, uint32_t X2, uint32_t Y, int bid) {
    uint32_t X = (X1 & mask) ^ X2;
    uint32_t MAT;

    X ^= X << sh1_tbl[bid];
    Y = X ^ (Y >> sh2_tbl[bid]);
    MAT = tex1Dfetch(tex_param_ref, bid * 16 + (Y & 0x0f));
    return Y ^ MAT;
}

/**
 * The tempering function.
 *
 * @param[in] V the output value should be tempered.
 * @param[in] T the tempering helper value.
 * @param[in] bid block id.
 * @return the tempered value.
 */
__device__ uint32_t temper(uint32_t V, uint32_t T, int bid) {
    uint32_t MAT;

    T ^= T >> 16;
    T ^= T >> 8;
    MAT = tex1Dfetch(tex_temper_ref, bid * 16 + (T & 0x0f));
    return V ^ MAT;
}

/**
 * The tempering and converting function.
 * By using the preset-ted table, converting to IEEE format
 * and tempering are done simultaneously.
 *
 * @param[in] V the output value should be tempered.
 * @param[in] T the tempering helper value.
 * @param[in] bid block id.
 * @return the tempered and converted value.
 */
__device__ uint32_t temper_single(uint32_t V, uint32_t T, int bid) {
    uint32_t MAT;
    uint32_t r;

    T ^= T >> 16;
    T ^= T >> 8;
    MAT = tex1Dfetch(tex_single_ref, bid * 16 + (T & 0x0f));
    r = (V >> 9) ^ MAT;
    return r;
}

/**
 * Read the internal state vector from kernel I/O data, and
 * put them into shared memory.
 *
 * @param[out] status shared memory.
 * @param[in] d_status kernel I/O data
 * @param[in] bid block id
 * @param[in] tid thread id
 */
__device__ void status_read(uint32_t status[LARGE_SIZE],
			    const mtgp32_kernel_status_t *d_status,
			    int bid,
			    int tid) {
    status[LARGE_SIZE - N + tid] = d_status[bid].status[tid];
    status[LARGE_SIZE - N + THREAD_NUM + tid]
	= d_status[bid].status[THREAD_NUM + tid];
    if (tid < N - THREAD_NUM) {
	status[6 * THREAD_NUM - N + tid]
	    = d_status[bid].status[2 * THREAD_NUM + tid];
    }
    __syncthreads();
}

/**
 * Read the internal state vector from shared memory, and
 * write them into kernel I/O data.
 *
 * @param[out] d_status kernel I/O data
 * @param[in] status shared memory.
 * @param[in] bid block id
 * @param[in] tid thread id
 */
__device__ void status_write(mtgp32_kernel_status_t *d_status,
			     const uint32_t status[LARGE_SIZE],
			     int bid,
			     int tid) {
    d_status[bid].status[tid] = status[LARGE_SIZE - N + tid];
    d_status[bid].status[THREAD_NUM + tid]
	= status[LARGE_SIZE - N + THREAD_NUM + tid];
    if (tid < N - THREAD_NUM) {
	d_status[bid].status[2 * THREAD_NUM + tid]
	    = status[6 * THREAD_NUM - N + tid];
    }
    __syncthreads();
}

/**
 * kernel function.
 * This function generates 32-bit unsigned integers in d_data
 *
 * @params[in,out] d_status kernel I/O data
 * @params[out] d_data output
 * @params[in] size number of output data requested.
 */
__global__ void mtgp32_uint32_kernel(mtgp32_kernel_status_t* d_status,
				     uint32_t* d_data, int size) {
    const int bid = blockIdx.x;
    const int tid = threadIdx.x;
    int pos = pos_tbl[bid];
    uint32_t r;
    uint32_t o;

    // copy status data from global memory to shared memory.
    status_read(status, d_status, bid, tid);

    // main loop
    for (int i = 0; i < size; i += LARGE_SIZE) {
	/* 1 */
	r = para_rec(status[LARGE_SIZE - N + tid],
		 status[LARGE_SIZE - N + tid + 1],
		 status[LARGE_SIZE - N + tid + pos],
		 bid);
	status[tid] = r;
	o = temper(r, status[LARGE_SIZE - N + tid + pos - 1], bid);
	d_data[size * bid + i + tid] = o;
	//__syncthreads();
	/* 2 */
	r = para_rec(status[(5 * THREAD_NUM - N + tid) % LARGE_SIZE],
		     status[(5 * THREAD_NUM - N + tid + 1) % LARGE_SIZE],
		     status[(5 * THREAD_NUM - N + tid + pos) % LARGE_SIZE],
		     bid);
	status[tid + THREAD_NUM] = r;
	o = temper(r,
		   status[(5 * THREAD_NUM - N + tid + pos - 1) % LARGE_SIZE],
		   bid);
	d_data[size * bid + THREAD_NUM + i + tid] = o;
	__syncthreads();
	/* 3 */
	r = para_rec(status[6 * THREAD_NUM - N + tid],
		     status[6 * THREAD_NUM - N + tid + 1],
		     status[6 * THREAD_NUM - N + tid + pos],
		     bid);
	status[tid + 2 * THREAD_NUM] = r;
	o = temper(r, status[tid + pos - 1 + 6 * THREAD_NUM - N], bid);
	d_data[size * bid + 2 * THREAD_NUM + i + tid] = o;
	//__syncthreads();
	/* 4 */
	r = para_rec(status[3 * THREAD_NUM - N + tid],
		     status[3 * THREAD_NUM - N + tid + 1],
		     status[3 * THREAD_NUM - N + tid + pos],
		     bid);
	status[tid + 3 * THREAD_NUM] = r;
	o = temper(r, status[tid + pos - 1 + 3 * THREAD_NUM - N], bid);
	d_data[size * bid + 3 * THREAD_NUM + i + tid] = o;
	__syncthreads();
    }
    // write back status for next call
    status_write(d_status, status, bid, tid);
}

/**
 * kernel function.
 * This function generates single precision floating point numbers in d_data.
 *
 * @params[in,out] d_status kernel I/O data
 * @params[out] d_data output. IEEE single precision format.
 * @params[in] size number of output data requested.
 */
__global__ void mtgp32_single_kernel(mtgp32_kernel_status_t* d_status,
				     uint32_t* d_data, int size)
{

    const int bid = blockIdx.x;
    const int tid = threadIdx.x;
    int pos = pos_tbl[bid];
    uint32_t r;
    uint32_t o;

    // copy status data from global memory to shared memory.
    status_read(status, d_status, bid, tid);

    // main loop
    for (int i = 0; i < size; i += LARGE_SIZE) {
	/* 1 */
	r = para_rec(status[LARGE_SIZE - N + tid],
		     status[LARGE_SIZE - N + tid + 1],
		     status[LARGE_SIZE - N + tid + pos],
		     bid);
	status[tid] = r;
	o = temper_single(r, status[LARGE_SIZE - N + tid + pos - 1], bid);
	d_data[size * bid + i + tid] = o;
	//__syncthreads();
	/* 2 */
	r = para_rec(status[5 * THREAD_NUM - N + tid],
		     status[5 * THREAD_NUM - N + tid + 1],
		     status[5 * THREAD_NUM - N + tid + pos],
		     bid);
	status[tid + THREAD_NUM] = r;
	o = temper_single(r,
			  status[5 * THREAD_NUM - N + tid + pos - 1],
			  bid);
	d_data[size * bid + THREAD_NUM + i + tid] = o;
	__syncthreads();
	/* 3 */
	r = para_rec(status[(6 * THREAD_NUM - N + tid) % LARGE_SIZE],
		     status[(6 * THREAD_NUM - N + tid + 1) % LARGE_SIZE],
		     status[(6 * THREAD_NUM - N + tid + pos) % LARGE_SIZE],
		     bid);
	status[tid + 2 * THREAD_NUM] = r;
	o = temper_single(
	    r,
	    status[(tid + pos - 1 + 6 * THREAD_NUM - N) % LARGE_SIZE],
	    bid);
	d_data[size * bid + 2 * THREAD_NUM + i + tid] = o;
	//__syncthreads();
	/* 4 */
	r = para_rec(status[3 * THREAD_NUM - N + tid],
		     status[3 * THREAD_NUM - N + tid + 1],
		     status[3 * THREAD_NUM - N + tid + pos],
		     bid);
	status[tid + 3 * THREAD_NUM] = r;
	o = temper_single(r,
			  status[tid + pos - 1 + 3 * THREAD_NUM - N],
			  bid);
	d_data[size * bid + 3 * THREAD_NUM + i + tid] = o;
	__syncthreads();
    }
    // write back status for next call
    status_write(d_status, status, bid, tid);
}

/**
 * This function sets constants in device memory.
 * @param params input, MTGP32 parameters.
 */
void make_constant(const mtgp32_params_fast_t params[], int block_num) {
    const int size1 = sizeof(uint32_t) * block_num;
    uint32_t *h_pos_tbl;
    uint32_t *h_sh1_tbl;
    uint32_t *h_sh2_tbl;
#if 0
    uint32_t *h_mask;
#endif
    h_pos_tbl = (uint32_t *)malloc(size1);
    h_sh1_tbl = (uint32_t *)malloc(size1);
    h_sh2_tbl = (uint32_t *)malloc(size1);
#if 0
    h_mask = (uint32_t *)malloc(sizeof(uint32_t));
#endif
    if (h_pos_tbl == NULL
	|| h_sh1_tbl == NULL
	|| h_sh2_tbl == NULL
#if 0
	|| h_mask == NULL
#endif
	) {
	printf("failure in allocating host memory for constant table.\n");
	exit(1);
    }
#if 0
    h_mask = params[0].mask;
#endif
    for (int i = 0; i < block_num; i++) {
	h_pos_tbl[i] = params[i].pos;
	h_sh1_tbl[i] = params[i].sh1;
	h_sh2_tbl[i] = params[i].sh2;
    }
    // copy from malloc area only
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(pos_tbl, h_pos_tbl, size1));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(sh1_tbl, h_sh1_tbl, size1));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(sh2_tbl, h_sh2_tbl, size1));
#if 0
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(&mask,
				      &h_mask, sizeof(uint32_t)));
#endif
    free(h_pos_tbl);
    free(h_sh1_tbl);
    free(h_sh2_tbl);
#if 0
    free(h_mask);
#endif
}

/**
 * This function sets texture lookup table.
 * @param params input, MTGP32 parameters.
 * @param d_texture_tbl device memory used for texture bind
 * @param block_num block number used for kernel call
 */
void make_texture(const mtgp32_params_fast_t params[],
		  uint32_t *d_texture_tbl[3],
		  int block_num) {
    const int count = block_num * TBL_SIZE;
    const int size = sizeof(uint32_t) * count;
    uint32_t *h_texture_tbl[3];
    int i, j;
    for (i = 0; i < 3; i++) {
	h_texture_tbl[i] = (uint32_t *)malloc(size);
	if (h_texture_tbl[i] == NULL) {
	    for (j = 0; j < i; j++) {
		free(h_texture_tbl[i]);
	    }
	    printf("failure in allocating host memory for constant table.\n");
	    exit(1);
	}
    }
    for (int i = 0; i < block_num; i++) {
	for (int j = 0; j < TBL_SIZE; j++) {
	    h_texture_tbl[0][i * TBL_SIZE + j] = params[i].tbl[j];
	    h_texture_tbl[1][i * TBL_SIZE + j] = params[i].tmp_tbl[j];
	    h_texture_tbl[2][i * TBL_SIZE + j] = params[i].flt_tmp_tbl[j];
	}
    }
    CUDA_SAFE_CALL(cudaMemcpy(d_texture_tbl[0], h_texture_tbl[0], size,
			      cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_texture_tbl[1], h_texture_tbl[1], size,
			      cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_texture_tbl[2], h_texture_tbl[2], size,
			      cudaMemcpyHostToDevice));
    tex_param_ref.filterMode = cudaFilterModePoint;
    tex_temper_ref.filterMode = cudaFilterModePoint;
    tex_single_ref.filterMode = cudaFilterModePoint;
    CUDA_SAFE_CALL(cudaBindTexture(0, tex_param_ref, d_texture_tbl[0], size));
    CUDA_SAFE_CALL(cudaBindTexture(0, tex_temper_ref, d_texture_tbl[1], size));
    CUDA_SAFE_CALL(cudaBindTexture(0, tex_single_ref, d_texture_tbl[2], size));
    free(h_texture_tbl[0]);
    free(h_texture_tbl[1]);
    free(h_texture_tbl[2]);
}

/**
 * This function initializes kernel I/O data.
 * @param d_status output kernel I/O data.
 * @param params MTGP32 parameters. needed for the initialization.
 */
void make_kernel_data(mtgp32_kernel_status_t *d_status,
		      mtgp32_params_fast_t params[],
		      int block_num) {
    mtgp32_kernel_status_t* h_status = (mtgp32_kernel_status_t *) malloc(
	sizeof(mtgp32_kernel_status_t) * block_num);

    if (h_status == NULL) {
	printf("failure in allocating host memory for kernel I/O data.\n");
	exit(8);
    }
    for (int i = 0; i < block_num; i++) {
	mtgp32_init_state(&(h_status[i].status[0]), &params[i], i + 1);
    }
#if defined(DEBUG)
    printf("h_status[0].status[0]:%08"PRIx32"\n", h_status[0].status[0]);
    printf("h_status[0].status[1]:%08"PRIx32"\n", h_status[0].status[1]);
    printf("h_status[0].status[2]:%08"PRIx32"\n", h_status[0].status[2]);
    printf("h_status[0].status[3]:%08"PRIx32"\n", h_status[0].status[3]);
#endif
    CUDA_SAFE_CALL(cudaMemcpy(d_status,
			      h_status,
			      sizeof(mtgp32_kernel_status_t) * block_num,
			      cudaMemcpyHostToDevice));
    free(h_status);
}

/**
 * This function is used to compare the outputs with C program's.
 * @param array data to be printed.
 * @param size size of array.
 * @param block number of blocks.
 */
void print_float_array(const float array[], int size, int block) {
    int b = size / block;

    for (int j = 0; j < 5; j += 5) {
	printf("%.10f %.10f %.10f %.10f %.10f\n",
	       array[j], array[j + 1],
	       array[j + 2], array[j + 3], array[j + 4]);
    }
    for (int i = 1; i < block; i++) {
	for (int j = -5; j < 5; j += 5) {
	    printf("%.10f %.10f %.10f %.10f %.10f\n",
		   array[b * i + j],
		   array[b * i + j + 1],
		   array[b * i + j + 2],
		   array[b * i + j + 3],
		   array[b * i + j + 4]);
	}
    }
    for (int j = -5; j < 0; j += 5) {
	printf("%.10f %.10f %.10f %.10f %.10f\n",
	       array[size + j],
	       array[size + j + 1],
	       array[size + j + 2],
	       array[size + j + 3],
	       array[size + j + 4]);
    }
}

/**
 * This function is used to compare the outputs with C program's.
 * @param array data to be printed.
 * @param size size of array.
 * @param block number of blocks.
 */
void print_uint32_array(uint32_t array[], int size, int block) {
    int b = size / block;

    for (int j = 0; j < 5; j += 5) {
	printf("%10" PRIu32 " %10" PRIu32 " %10" PRIu32
	       " %10" PRIu32 " %10" PRIu32 "\n",
	       array[j], array[j + 1],
	       array[j + 2], array[j + 3], array[j + 4]);
    }
    for (int i = 1; i < block; i++) {
	for (int j = -5; j < 5; j += 5) {
	    printf("%10" PRIu32 " %10" PRIu32 " %10" PRIu32
		   " %10" PRIu32 " %10" PRIu32 "\n",
		   array[b * i + j],
		   array[b * i + j + 1],
		   array[b * i + j + 2],
		   array[b * i + j + 3],
		   array[b * i + j + 4]);
	}
    }
    for (int j = -5; j < 0; j += 5) {
	printf("%10" PRIu32 " %10" PRIu32 " %10" PRIu32
	       " %10" PRIu32 " %10" PRIu32 "\n",
	       array[size + j],
	       array[size + j + 1],
	       array[size + j + 2],
	       array[size + j + 3],
	       array[size + j + 4]);
    }
}

/**
 * host function.
 * This function calls corresponding kernel function.
 *
 * @param d_status kernel I/O data.
 * @param num_data number of data to be generated.
 */
void make_uint32_random(mtgp32_kernel_status_t* d_status,
			int num_data,
			int block_num) {
    uint32_t* d_data;
    unsigned int timer = 0;
    uint32_t* h_data;
    cudaError_t e;
    float gputime;

    printf("generating 32-bit unsigned random numbers.\n");
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_data, sizeof(uint32_t) * num_data));
    CUT_SAFE_CALL(cutCreateTimer(&timer));
    h_data = (uint32_t *) malloc(sizeof(uint32_t) * num_data);
    if (h_data == NULL) {
	printf("failure in allocating host memory for output data.\n");
	exit(1);
    }
    CUT_SAFE_CALL(cutStartTimer(timer));
    if (cudaGetLastError() != cudaSuccess) {
	printf("error has been occured before kernel call.\n");
	exit(1);
    }

    /* kernel call */
    mtgp32_uint32_kernel<<< block_num, THREAD_NUM>>>(
	d_status, d_data, num_data / block_num);
    cudaThreadSynchronize();

    e = cudaGetLastError();
    if (e != cudaSuccess) {
	printf("failure in kernel call.\n%s\n", cudaGetErrorString(e));
	exit(1);
    }
    CUT_SAFE_CALL(cutStopTimer(timer));
    CUDA_SAFE_CALL(
	cudaMemcpy(h_data,
		   d_data,
		   sizeof(uint32_t) * num_data,
		   cudaMemcpyDeviceToHost));
    gputime = cutGetTimerValue(timer);
    print_uint32_array(h_data, num_data, block_num);
    printf("generated numbers: %d\n", num_data);
    printf("Processing time: %f (ms)\n", gputime);
    printf("Samples per second: %E \n", num_data / (gputime * 0.001));
    CUT_SAFE_CALL(cutDeleteTimer(timer));
    //free memories
    free(h_data);
    CUDA_SAFE_CALL(cudaFree(d_data));
}

/**
 * host function.
 * This function calls corresponding kernel function.
 *
 * @param d_status kernel I/O data.
 * @param num_data number of data to be generated.
 */
void make_single_random(mtgp32_kernel_status_t* d_status,
			int num_data,
			int block_num) {
    uint32_t* d_data;
    unsigned int timer = 0;
    float* h_data;
    cudaError_t e;
    float gputime;

    printf("generating single precision floating point random numbers.\n");
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_data, sizeof(uint32_t) * num_data));
    CUT_SAFE_CALL(cutCreateTimer(&timer));
    h_data = (float *) malloc(sizeof(float) * num_data);
    if (h_data == NULL) {
	printf("failure in allocating host memory for output data.\n");
	exit(1);
    }
    CUT_SAFE_CALL(cutStartTimer(timer));
    if (cudaGetLastError() != cudaSuccess) {
	printf("error has been occured before kernel call.\n");
	exit(1);
    }

    /* kernel call */
    mtgp32_single_kernel<<< block_num, THREAD_NUM >>>(
	d_status, d_data, num_data / block_num);
    cudaThreadSynchronize();

    e = cudaGetLastError();
    if (e != cudaSuccess) {
	printf("failure in kernel call.\n%s\n", cudaGetErrorString(e));
	exit(1);
    }
    CUT_SAFE_CALL(cutStopTimer(timer));
    CUDA_SAFE_CALL(
	cudaMemcpy(h_data,
		   d_data,
		   sizeof(uint32_t) * num_data,
		   cudaMemcpyDeviceToHost));
    gputime = cutGetTimerValue(timer);
    print_float_array(h_data, num_data, block_num);
    printf("generated numbers: %d\n", num_data);
    printf("Processing time: %f (ms)\n", gputime);
    printf("Samples per second: %E \n", num_data / (gputime * 0.001));
    CUT_SAFE_CALL(cutDeleteTimer(timer));
    //free memories
    free(h_data);
    CUDA_SAFE_CALL(cudaFree(d_data));
}

int main(int argc, char *argv[])
{
    // LARGE_SIZE is a multiple of 16
    int num_data = 10000000;
    int block_num;
    int num_unit;
    int r;
    mtgp32_kernel_status_t *d_status;
    uint32_t *d_texture[3];

    if (argc >= 2) {
	errno = 0;
	block_num = strtol(argv[1], NULL, 10);
	if (errno) {
	    printf("%s number_of_block number_of_output\n", argv[0]);
	    return 1;
	}
	if (block_num < 1 || block_num > BLOCK_NUM_MAX) {
	    printf("%s block_num should be between 1 and %d\n",
		   argv[0], BLOCK_NUM_MAX);
	    return 1;
	}
	errno = 0;
	num_data = strtol(argv[2], NULL, 10);
	if (errno) {
	    printf("%s number_of_block number_of_output\n", argv[0]);
	    return 1;
	}
	argc -= 2;
	argv += 2;
    } else {
	printf("%s number_of_block number_of_output\n", argv[0]);
	return 1;
    }
    CUT_DEVICE_INIT(argc, argv);

    num_unit = LARGE_SIZE * block_num;
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_status,
			      sizeof(mtgp32_kernel_status_t) * block_num));
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_texture[0],
			      sizeof(uint32_t) * block_num * TBL_SIZE));
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_texture[1],
			      sizeof(uint32_t) * block_num * TBL_SIZE));
    CUDA_SAFE_CALL(cudaMalloc((void**)&d_texture[2],
			      sizeof(uint32_t) * block_num * TBL_SIZE));
    r = num_data % num_unit;
    if (r != 0) {
	num_data = num_data + num_unit - r;
    }
    make_constant(mtgp32_params_fast_23209, block_num);
    make_texture(mtgp32_params_fast_23209, d_texture, block_num);
    make_kernel_data(d_status, mtgp32_params_fast_23209, block_num);
    make_uint32_random(d_status, num_data, block_num);
    make_single_random(d_status, num_data, block_num);

    //finalize
    CUDA_SAFE_CALL(cudaFree(d_status));
    CUDA_SAFE_CALL(cudaFree(d_texture[0]));
    CUDA_SAFE_CALL(cudaFree(d_texture[1]));
    CUDA_SAFE_CALL(cudaFree(d_texture[2]));
    CUT_EXIT(argc, argv);
}
