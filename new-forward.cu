#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"
#define kernel_size 7
#define max_inputs 4
__global__ void conv_forward_kernel(float* y, const float* __restrict__ x, const float* __restrict__ k, const int B, const int M, const int C, const int H, const int W, const int K)
{

    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.
    We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    */

    const int H_out = H - kernel_size + 1; // TOTAL HEIGHT OF EVERY IMAGE STORED IN Y 
    const int W_out = W - kernel_size + 1; // TOTAL WIDTH OF EVERY IMAGE STORED IN X

// An example use of these macros:
// float a = y4d(0,0,0,0)
// y4d(0,0,0,0) = a
#define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
#define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
#define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]



    // POSSIBLE SPEED UPS:

    //1) delete if statement- if no bounds are ever overdrawn no reason to check
    //2) unroll loops to do 2/3/4 computations at once
    //3) load convolution kernel into shared memory 
    //4) store input matrix and kernel matrix in constant memory? 

     // each thread calculates a SINGLE output pixel, on a SINGULAR image and channel.
     // X axis corresponds to image
     // y axis corresponds to output channel
     // z axis corresponds to row and width.

     // curr image we are looking at 
     int currImage = blockIdx.x;
     // curr channel in the image we are looking at
     int currChannel = blockIdx.y;
     // z axis refers to BOTH ROW + COLUMN- must seperate the two!
     int currRow = ((blockDim.z * blockIdx.z) + threadIdx.z) / W_out;
     int currColumn = ((blockDim.z * blockIdx.z) + threadIdx.z) % W_out;

     // load global variable into register for quicker access
     int inputChannels = C;
     /*
     //shared tile used for quicker loads from kernel matrix
     __shared__ float kernelTile[kernel_size][kernel_size][max_inputs];
     
     //if row/column correspond to kernel positions, load them into tile
     if(currRow < kernel_size && currColumn < kernel_size) {
	     //for loop ensures all input channel kernels are loaded
	     for(int c = 0 ; c < inputChannels; c++) {
		     kernelTile[currRow][currColumn][c] = k4d(currChannel, c, currRow, currColumn);
	     }
     }
     // ensure kernel is fully loaded before performing convolution
     __syncthreads();
     */

     // after getting all of our necessary perameters we do a bounds check: 
     //not necessary to check bounds on image, or channel as we are garunteed no overflow in kernel call
     if(currRow < H_out && currColumn < W_out) {
         // if everything is in bounds proceed to calculate convolution for current output
         y4d(currImage, currChannel, currRow , currColumn) = 0; // zero everything out before calculation!
         // loop over number of input channels
         for(int c = 0; c < inputChannels; c++) {           
     	     // loop over convolution matrix (no need to take into account halos as output is smaller then input)
             for(int p = 0; p < kernel_size; p++) { // p corresponds to height, q to width
                 for(int q = 0; q < kernel_size; q++) {
		     y4d(currImage, currChannel, currRow, currColumn) += 
		     x4d(currImage, c, currRow +  p, currColumn + q) * k4d(currChannel, c, p, q); // kernelTile[p][q][c];
		 }
	     }
	 }
     }

#undef y4d
#undef x4d
#undef k4d
}
// INPUT PERAMETERS
// host_y - pointer to output data
// host_x - pointer to input data
// host_k - pointer to host convolution matrix
// device_y_ptr - pointer to a pointer to output data
// device_x_ptr - pointer to a pointer to input data
// device_k_ptr - pointer to a pointer to device convolution matrix
// B = batch_size - total number of different images stored in x
// M = number of output feature maps - total number of outputs to put in y - number of channels in Y! 
// C = number of input feature maps -  total amount of inputs stored in x - number of channels in X!
// H = height of input images stored in x
// W = width of input images stored in x
// K = height and width of convolution matrix



	
__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_y, const float *host_x, const float *host_k, float **device_y_ptr, float **device_x_ptr, float **device_k_ptr, const int B, const int M, const int C, const int H, const int W, const int K) {

    // Allocate memory and copy over the relevant data structures to the GPU

    // no need to copy y as output is not set yet.
    
    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.

    // Useful snippet for error checking
    // cudaError_t error = cudaGetLastError();
    // if(error != cudaSuccess)
    // {
    //     std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
    //     exit(-1);
    // }

	// CUDAMALLOC CALLS:               Height of single image * width of single image * number of images * size of float.
	cudaMalloc((void **) device_y_ptr, (H - K + 1) * (W - K + 1) * M * B * sizeof(float)); 
	cudaMalloc((void **) device_x_ptr, B * C * H * W  * sizeof(float)); 
	cudaMalloc((void **) device_k_ptr, K * K * M * C  * sizeof(float)); // different convolution matrix for every channel!

	// CUDA MEMCPY CALLS:
	// no need to copy y as it is empty
	cudaMemcpy(*device_x_ptr, host_x, B * C * H * W *  sizeof(float), cudaMemcpyHostToDevice);
	cudaMemcpy(*device_k_ptr, host_k, K * K * M * C *  sizeof(float), cudaMemcpyHostToDevice);

}


__host__ void GPUInterface::conv_forward_gpu(float *device_y, const float *device_x, const float *device_k, const int B, const int M, const int C, const int H, const int W, const int K)
{
    
// each thread calculates a single output channel pixel
// each block calculates 64  output pixels on a single channel and a single image
// grid dimensions:
// X = what image we are currently operating on
// Y = what channel we are currently operating on
// Z = what row and column we are currently operating on	

    dim3 blockDim(1,1,64); 
//(number of images, number of output channels , rows + columns)
    dim3 gridDim(B, M, (((H - K + 1) * (W - K + 1)) / 64) + 1);  
    conv_forward_kernel<<<gridDim, blockDim>>>(device_y, device_x, device_k, B, M, C, H, W, K);
}


__host__ void GPUInterface::conv_forward_gpu_epilog(float *host_y, float *device_y, float *device_x, float *device_k, const int B, const int M, const int C, const int H, const int W, const int K)
{
    // Copy the output back to host

	cudaMemcpy(host_y, device_y, (H - K + 1) * (W - K + 1) * M * B * sizeof(float) , cudaMemcpyDeviceToHost);

    // Free device memory

	cudaFree(device_y); cudaFree(device_x); cudaFree(device_k);
}


__host__ void GPUInterface::get_device_properties()
{
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for(int dev = 0; dev < deviceCount; dev++)
    {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout<<"Device "<<dev<<" name: "<<deviceProp.name<<std::endl;
        std::cout<<"Computational capabilities: "<<deviceProp.major<<"."<<deviceProp.minor<<std::endl;
        std::cout<<"Max Global memory size: "<<deviceProp.totalGlobalMem<<std::endl;
        std::cout<<"Max Constant memory size: "<<deviceProp.totalConstMem<<std::endl;
        std::cout<<"Max Shared memory size per block: "<<deviceProp.sharedMemPerBlock<<std::endl;
        std::cout<<"Max threads per block: "<<deviceProp.maxThreadsPerBlock<<std::endl;
        std::cout<<"Max block dimensions: "<<deviceProp.maxThreadsDim[0]<<" x, "<<deviceProp.maxThreadsDim[1]<<" y, "<<deviceProp.maxThreadsDim[2]<<" z"<<std::endl;
        std::cout<<"Max grid dimensions: "<<deviceProp.maxGridSize[0]<<" x, "<<deviceProp.maxGridSize[1]<<" y, "<<deviceProp.maxGridSize[2]<<" z"<<std::endl;
        std::cout<<"Warp Size: "<<deviceProp.warpSize<<std::endl;
    }
}
