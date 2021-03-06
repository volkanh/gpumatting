/* main.cu is part of gpumatting and is 
 * Copyright 2013 Philip G. Lee <rocketman768@gmail.com>
 * 
 * gpumatting is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * gpumatting is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with gpumatting.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <cuda.h>
#include <time.h>
#include "ppm.h"
#include "BandedMatrix.h"
#include "BandedMatrix.cu"
#include "Matting.cu"
#include "Vector.cu"
#include "SLIC.h"
#include "Solve.h"

//! \brief Print help message and exit.
void help();
//! \brief Dump vector to stdout in %.5e format.
void dump1D( float* a, int n );
//! \brief Dump row-major matrix to stdout in %.5e format.
void dump2D( float* a, int rows, int cols, size_t pitch );
void dump( BandedMatrix const& bm );

/*!
 * \brief Solve L*alpha = b by gradient descent.
 * 
 * \param alpha device vector of size L.rows padded properly to make \c L * \c alpha work.
 * \param L device banded matrix
 * \param b device vector of size L.rows
 * \param iterations number of gradient descent steps before termination
 * \param pad The size of left and right vector padding to make \c L * x work for a vector x.
 */
void gradSolve( float* alpha, BandedMatrix L, float* b, int iterations, int pad);
/*!
 * \brief Solve L*alpha = b by conjugate-gradient descent.
 * 
 * \param alpha device vector of size L.rows padded properly to make \c L * \c alpha work.
 * \param L device banded matrix
 * \param b device vector of size L.rows
 * \param pad The size of left and right vector padding to make \c L * x work for a vector x.
 * \param iterations number of steps before termination
 * \param restartInterval restart cg after this many iterations (typically about 50)
 */
void cgSolve( float* alpha, BandedMatrix L, float* b, int pad, int iterations, int restartInterval);
/*!
 * \brief Compute and display matte ground truth errors.
 *
 * \param alpha Computed alpha matte
 * \param gtAlpha Ground truth alpha matte
 * \param imW Matte width
 * \param imH Matte height
 */
void computeError( float* alpha, float* gtAlpha, int imW, int imH );
/*!
 * \brief Jacobi relaxation
 * 
 * \param x Device pointer for result
 * \param a Matrix
 * \param b Right-hand-side
 * \param omega Damping coefficient.
 * \param pad padding of \c x
 * \param iterations Number of smoothings to do.
 */
void jacobi(
   float* x,
   const BandedMatrix a,
   float const* b,
   float omega,
   int pad,
   int iterations
);

float* vector_host(size_t n, size_t padding)
{
   float* ret = new float[n+2*padding];
   ret += padding;
   return ret;
}

void free_vector_host(float* vec, size_t padding)
{
   vec -= padding;
   delete[] vec;
}

int myceildiv(int a, int b)
{
   if( a % b != 0 )
      ++a;
   return a/b;
}

int main(int argc, char* argv[])
{
   enum Solver{SOLVER_GRAD, SOLVER_CG, SOLVER_JACOBI_HOST, SOLVER_GS_HOST};
   Solver solver = SOLVER_CG;
   float4* im;
   unsigned char* charIm;
   unsigned char* scribs;
   int* labels;
   unsigned int numLabels;
   float* b;
   float* dB;
   float* alpha;
   float* alphaPad;
   float* dAlpha;
   int dAlpha_pad;
   float* alphaGt = 0;
   int imW, imH;
   int scribW, scribH;
   int gtW, gtH;
   int i;
   int iterations;
   clock_t beg,end;
   BandedMatrix L, dL;
   
   if( argc < 5 )
      help();
   
   //==================HOST DATA====================
      
   // Parse the options.
   if( strncmp(argv[1],"grad",4)==0 )
      solver = SOLVER_GRAD;
   else if( strncmp(argv[1],"cg",2) == 0 )
      solver = SOLVER_CG;
   else if( strncmp(argv[1],"cpu-jacobi",10) == 0 )
      solver = SOLVER_JACOBI_HOST;
   else
      solver = SOLVER_GS_HOST;
   
   iterations = atoi(argv[2]);
   im = ppmread_float4( &charIm, argv[3], &imW, &imH );
   scribs = pgmread( argv[4], &scribW, &scribH );
   if( scribW != imW || scribH != imH )
   {
      fprintf(
         stderr,
         "ERROR: scribbles not the same size as the image.\n"
         "  %d x %d vs. %d x %d\n",
         scribW, scribH, imW, imH
      );
      exit(1);
   }
   if( argc > 5 )
      alphaGt = pgmread_float( argv[5], &gtW, &gtH );
   
   L.rows = imW*imH;
   L.cols = L.rows;
   // Setup bands===
   L.nbands = 25;
   L.bands = (int*)malloc(L.nbands*sizeof(int));
   L.bands[12+0] = 0;
   L.bands[12+1] = 1;
   L.bands[12+2] = 2;
   L.bands[12+3] = imW-2;
   L.bands[12+4] = imW-1;
   L.bands[12+5] = imW;
   L.bands[12+6] = imW+1;
   L.bands[12+7] = imW+2;
   L.bands[12+8] = 2*imW-2;
   L.bands[12+9] = 2*imW-1;
   L.bands[12+10] = 2*imW;
   L.bands[12+11] = 2*imW+1;
   L.bands[12+12] = 2*imW+2;
   L.bands[12-1] = -1;
   L.bands[12-2] = -2;
   L.bands[12-3] = -(imW-2);
   L.bands[12-4] = -(imW-1);
   L.bands[12-5] = -(imW);
   L.bands[12-6] = -(imW+1);
   L.bands[12-7] = -(imW+2);
   L.bands[12-8] = -(2*imW-2);
   L.bands[12-9] = -(2*imW-1);
   L.bands[12-10] = -(2*imW);
   L.bands[12-11] = -(2*imW+1);
   L.bands[12-12] = -(2*imW+2);
   // Setup nonzeros===
   L.a = (float*)malloc( L.nbands*L.rows * sizeof(float));
   memset( L.a, 0x00, L.nbands*L.rows * sizeof(float));
   L.apitch = L.rows;
   
   b = (float*)malloc( L.rows * sizeof(float) );
   alpha = (float*)malloc(L.rows * sizeof(float));
   for( i = 0; i < L.rows; ++i )
      alpha[i] = 0.5f;
   
   // SLIC
   //labels = (int*)malloc(imW*imH*sizeof(int));
   //beg = clock();
   //unsigned char* imArgb = rgbToArgb(charIm, imW, imH);
   //numLabels = slicSegmentation( labels, (unsigned int*)imArgb, imW, imH, 200, 10.0 );
   //end = clock();
   //fprintf(stderr, "numlabels: %d\n", numLabels);
   //fprintf(stderr,"SLIC segmentation: %.2es\n", (double)(end-beg)/CLOCKS_PER_SEC);
   // Dump to screen
   //for( int v = 0; v < imH; ++v )
   //{
   //   for( int u = 0; u < imW; ++u )
   //      printf("%d, ", labels[u+v*imW]);
   //   printf("\n");
   //}
   //free(imArgb);
   //return 0;
   // END SLIC
   
   beg = clock();
   // WARNING: regularization param < 1e-3 seems to make the Laplacian unstable.
   hostLevinLaplacian(L, b, 1e-2, im, scribs, imW, imH, imW);
   end = clock();
   fprintf(stderr,"Laplacian generation: %.2es\n", (double)(end-beg)/CLOCKS_PER_SEC);
   dump(L);
   //------------------------------------------------
   
   // Pad alpha by a multiple of 32 that is larger than (2*imW+2).
   dAlpha_pad = ((2*imW+2)/32)*32+32;
   
   bool cpuSolver = (solver == SOLVER_JACOBI_HOST || solver == SOLVER_GS_HOST);
   
   //=================GPU Time=======================
   
   // Pre-solve
   if( cpuSolver )
   {
      alphaPad = vector_host(imW*imH, dAlpha_pad);
      memcpy( alphaPad, alpha, imW*imH*sizeof(float) );
   }
   else
   {
      cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
      bmCopyToDevice( &dL, &L );
      
      cudaMalloc((void**)&dB, L.rows*sizeof(float));
      cudaMemcpy((void*)dB, (void*)b, L.rows*sizeof(float), cudaMemcpyHostToDevice);
      
      vecCopyToDevice(&dAlpha, alpha, L.rows, dAlpha_pad, dAlpha_pad);
   }
   
   //+++++++++++++++++++++++++++++
   switch( solver )
   {
      case SOLVER_GRAD:
         gradSolve(dAlpha, dL, dB, iterations, dAlpha_pad);
         cudaMemcpy( (void*)alpha, (void*)dAlpha, L.rows*sizeof(float), cudaMemcpyDeviceToHost );
         break;
      case SOLVER_CG:
         cgSolve(dAlpha, dL, dB, dAlpha_pad, iterations, 101);
         cudaMemcpy( (void*)alpha, (void*)dAlpha, L.rows*sizeof(float), cudaMemcpyDeviceToHost );
         break;
      case SOLVER_JACOBI_HOST:
         jacobi_host( alphaPad, L, b, iterations, dAlpha_pad, 2.f/3.f );
         break;
      case SOLVER_GS_HOST:
         gaussSeidel_host( alphaPad, L, b, iterations );
         break;
      default:
         break;
   }
   //+++++++++++++++++++++++++++++
   
   // Post-solve
   if( cpuSolver )
   {
      memcpy( alpha, alphaPad, imW*imH*sizeof(float) );
      free_vector_host( alphaPad, dAlpha_pad );
   }
   else
   {
      cudaMemcpy( (void*)alpha, (void*)dAlpha, L.rows*sizeof(float), cudaMemcpyDeviceToHost );
      
      vecDeviceFree( dAlpha, dAlpha_pad );
      cudaFree(dB);
      bmDeviceFree( &dL );
      cudaDeviceSynchronize();
   }
   //------------------------------------------------
   
   // Print any errors
   cudaError_t code = cudaGetLastError(); 
   const char* error_str = cudaGetErrorString(code);
   if( code )
      fprintf(stderr, "ERROR: %s\n", error_str);
   
   // Print some stats
   //printf("Pitch: %lu, %lu\n", L.apitch, dL.apitch);
   //printf("rows, nbands: %d, %d\n", dL.rows, dL.nbands);
   printf("Image Size: %d x %d\n", imW, imH );
   
   if(alphaGt)
      computeError(alpha, alphaGt, imW, imH);
   
   pgmwrite_float("alpha.pgm", imW, imH, alpha, "", 1);
   
   free(alpha);
   free(b);
   free(L.a);
   free(L.bands);
   free(labels);
   free(scribs);
   free(im);
   free(charIm);
   return 0;
}

void help()
{
   fprintf(
      stderr,
      "Usage: matting <solver> <iter> <image>.ppm <scribbles>.pgm [<gt>.pgm]\n"
      "  solver    - \"grad\" (gradient), \"cg\" (conjugate-gradient),\n"
      "              \"cpu-jacobi\" (CPU Jacobi iteration), \"cpu-gauss-seidel\"\n"
      "  iter      - Number of iterations for the solver\n"
      "  image     - An RGB image to matte\n"
      "  scribbles - Scribbles for the matte\n"
      "  gt        - Ground truth for the matte\n"
   );
   
   exit(0);
}

void dump( BandedMatrix const& bm )
{
   int i,j;
   fprintf(stderr,"%d\n", bm.rows);
   for( i = 0; i < bm.nbands; ++i )
      fprintf(stderr,"%d,", bm.bands[i]);
   printf("\n");
   /*
   for( i = 0; i < bm.nbands; ++i )
   {
      for( j = 0; j < bm.rows; ++j )
         printf("%.8e,", bm.a[j+i*bm.apitch]);
      printf("\n");
   }
   */
   FILE* fp = fopen("A.bin","wb");
   for( i = 0; i < bm.nbands; ++i )
   {
      fwrite(&(bm.a[i*bm.apitch]), sizeof(float), bm.rows, fp);
   }
   fclose(fp);
}

void dump1D( float* a, int n )
{
   int i;
   for( i = 0; i < n-1; ++i )
      printf("%.5e, ", a[i]);
   printf("%.5e\n", a[i]);
}

void dump2D( float* a, int rows, int cols, size_t pitch )
{
   int i,j;
   for( i = 0; i < rows; ++i )
   {
      for( j = 0; j < cols-1; ++j )
         printf("%.5e, ", a[j + i*pitch]);
      printf("%.5e\n", a[j + i*pitch]);
   }
}

__global__ void addScalar( float* k, float* val )
{
   *k += *val;
}

__global__ void subScalar( float* k, float* val )
{
   *k -= *val;
}

__global__ void multScalar( float* k, float* val )
{
   *k *= *val;
}

__global__ void multScalarConst( float* k, float val )
{
   *k *= val;
}

__global__ void divScalar( float* k, float* val )
{
   *k /= *val;
}

__global__ void divScalar2( float* lhs, float* num, float* den )
{
   *lhs = *num / *den;
}

void gradSolve( float* alpha, BandedMatrix L, float* b, int iterations, int pad)
{
   float* d;
   float* e;
   float* f;
   float* k;
   int N = L.rows;
   float* tmp;
   
   vecDeviceMalloc(&d, N, pad, pad);
   cudaMalloc((void**)&e, N*sizeof(float));
   vecDeviceMalloc(&f, N, pad, pad);
   cudaMalloc((void**)&k, 1*sizeof(float));
   cudaMalloc((void**)&tmp, 1*sizeof(float));
   
   cudaDeviceSynchronize();
   
   // Do the gradient descent iteration.
   while( iterations-- > 0 )
   {
      // d := L*alpha - b
      bmAxpy_k<17,false><<<16,1024>>>(d, L, alpha, b);
      
      // If the gradient magnitude is small enough, we're done.
      //innerProd(&tmp, d, d, N);
      
      // k := <d,b>
      innerProd_k<<<16,1024,1024*sizeof(float)>>>(k, d, b, N);
      
      // e := H*d
      bmAx_k<17><<<16,1024>>>(e, L, d);
      
      // k -= <e,alpha>
      innerProd_k<<<16,1024,1024*sizeof(float)>>>( tmp, e, alpha, N );
      subScalar<<<1,1>>>(k,tmp);
      
      // k /= <e,d>
      innerProd_k<<<16,1024,1024*sizeof(float)>>>( tmp, e, d, N );
      divScalar<<<1,1>>>(k, tmp);
      
      // alpha += k*d
      vecScale_k<<<16,1024>>>( d, d, k, N );
      vecAdd_k<<<16,1024>>>( alpha, alpha, d, N );
   }
   
   cudaFree(tmp);
   cudaFree(k);
   vecDeviceFree(f, pad);
   cudaFree(e);
   vecDeviceFree(d, pad);
}

void cgSolve( float* alpha, BandedMatrix L, float* b, int pad, int iterations, int restartInterval)
{
   float* r;
   float* p;
   float* Lp;
   float* kp;
   float* k;
   int N = L.rows;
   float* rTr;
   
   // This makes the first iteration gradient descent.
   int innerIter = 0;
   
   vecDeviceMalloc(&r, N, pad, pad);
   vecDeviceMalloc(&p, N, pad, pad);
   vecDeviceMalloc(&Lp, N, pad, pad);
   vecDeviceMalloc(&kp, N, 0, 0);
   cudaMalloc((void**)&k, 1*sizeof(float));
   cudaMalloc((void**)&rTr, 1*sizeof(float));
   
   cudaDeviceSynchronize();
   
   // Do the conjugate gradient iterations.
   while( iterations-- > 0 )
   {
      if( innerIter == 0 )
      {
         // r := L*alpha - b
         bmAxpy_k<17,false><<<16,1024>>>(r, L, alpha, b);
         // p = -r
         vecScaleConst_k<<<16,1024>>>(p, r, -1.0f, N);
         
         innerIter = restartInterval-1;
      }
      else
         --innerIter;
      
      // Lp := L*p
      bmAx_k<17><<<16,1024>>>(Lp, L, p);
      
      // k = <r,r>/<p,p>_L
      innerProd_k<<<16,1024,1024*sizeof(float)>>>(rTr, r, r, N);
      innerProd_k<<<16,1024,1024*sizeof(float)>>>(k, p, Lp, N);
      divScalar2<<<1,1>>>(k,rTr,k);
      
      // alpha += k*p
      vecScale_k<<<16,1024>>>(kp, p, k, N);
      vecAdd_k<<<16,1024>>>(alpha, alpha, kp, N);
      
      // r += k*L*p
      vecScale_k<<<16,1024>>>(Lp, Lp, k, N);
      vecAdd_k<<<16,1024>>>(r, r, Lp, N);
      
      // k = <r,r>/<r_old,r_old>
      innerProd_k<<<16,1024,1024*sizeof(float)>>>(k, r, r, N);
      divScalar<<<1,1>>>(k,rTr);
      
      // p = k*p - r;
      vecScale_k<<<16,1024>>>(kp, p, k, N);
      vecSub_k<<<16,1024>>>( p, kp, r, N );
   }
   
   cudaFree(rTr);
   cudaFree(k);
   vecDeviceFree(kp, 0);
   vecDeviceFree(Lp, pad);
   vecDeviceFree(p, pad);
   vecDeviceFree(r, pad);
}

void jacobi(
   float* x,
   const BandedMatrix a,
   float const* b,
   float omega,
   int pad,
   int iterations
)
{
   float* xx;
   float* xxTmp;
   float* xxOrig;
   
   vecDeviceMalloc(&xxOrig, a.rows, pad, pad);
   cudaDeviceSynchronize();
   xx = xxOrig;
   
   while( iterations-- > 0 )
   {
      jacobi_k<17><<<16,1024>>>(xx, x, a, b, omega);
      
      // Swap x and xx
      xxTmp = x;
      x = xx;
      xx = xxTmp;
   }
   
   vecDeviceFree(xxOrig, pad);
}

void computeError( float* alpha, float* gtAlpha, int imW, int imH )
{
   double ssd = 0.0;
   int i, j;
   
   for( i = 0; i < imH; ++i )
   {
      for( j = 0; j < imW; ++j )
      {
         if( alpha[j + i*imW] > 1.0f )
            ssd += (1.0f-gtAlpha[j+i*imW])*(1.0f-gtAlpha[j+i*imW]);
         else if( alpha[j + i*imW] < 0.0f )
            ssd += gtAlpha[j+i*imW] * gtAlpha[j+i*imW];
         else
            ssd += (alpha[j+i*imW]-gtAlpha[j+i*imW])*(alpha[j+i*imW]-gtAlpha[j+i*imW]);
      }
   }
   
   printf("Ground truth MSE: %.3e\n", ssd/(imW*imH));
}
