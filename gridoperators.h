/* gridoperators.h is part of gpumatting and is 
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

void downsampleOps(..., float const* im, int imW, int imH, int const* labels, int nlabels, int nlevels)
{
   // Coordinate matrix representation of a downsample operator.
   int* i;
   int* j;
   int* k;
   
   int numpix = imW*imH;
   int u,v;
   int curLabel;
   int prevNlabels;
   
   float tmp;
   float min;
   int minU, minV;
   int *__restrict__ mapping = (int*)malloc(nlabels*sizeof(int));
   int *__restrict__ merged = (int*)malloc(nlabels*sizeof(int));
   float *__restrict__ diffs = (float*)malloc(nlabels*nlabels*sizeof(float));
   float *__restrict__ means = (float*)malloc(3*nlabels*sizeof(float));
   int *__restrict__ segSize = (int*)malloc(nlabels*sizeof(int));
   memset(segSize, 0x00, nlabels*sizeof(int));
   ...
   
   // First level--------------------------------------------------------------
   memset(means, 0x00, 3*nlabels*sizeof(float));
   for( u = 0; u < numpix; ++u )
   {
      means[3*labels[u]+0] += im[4*u+0];
      means[3*labels[u]+1] += im[4*u+1];
      means[3*labels[u]+2] += im[4*u+2];
      
      ++segSize[labels[u]];
      i[u] = labels[u];
      j[u] = u;
      k[u] = 1.0f;
   }
   for( u = 0; u < nlabels; ++u )
      means[3*u+0] /= segSize[u]; means[3*u+1] /= segSize[u]; means[3*u+2] /= segSize[u];
   
   ...
   
   // Subsequent levels--------------------------------------------------------
   for( --nlevels; nlevels > 0; --nlevels )
   {
      prevNlabels = nlabels;
      curLabel = 0;
      memset(merged, 0x00, nlabels*sizeof(int));
      
      // diffs[u][v] = ||means[u]-means[v]||_2^2
      min = 1e6;
      for( u = 0; u < prevNlabels; ++u )
      {
         for( v = u+1, v < prevNlabels; ++v )
         {
            tmp = (means[3*u+0]-means[3*v+0]);
            tmp *= tmp;
            diffs[v + u * nlabels] = tmp;
            
            tmp = (means[3*u+1]-means[3*v+1]);
            tmp *= tmp;
            diffs[v + u * nlabels] += tmp;
            
            tmp = (means[3*u+2]-means[3*v+2]);
            tmp *= tmp;
            diffs[v + u * nlabels] += tmp;
         }
      }
      
      while( true )
      {
         min = 1e6;
         for( u = 0; u < prevNlabels; ++u )
         {
            if( merged[u] )
               continue;
            
            for( v = u+1, v < prevNlabels; ++v )
            {
               if( merged[v] )
                  continue;
               // NOTE: need to check here that segments u and v are spatially adjacent.
                  
               // Get location of minimum difference.
               if( diffs[v + u * nlabels] < min )
               {
                  min = diffs[v + u * nlabels]
                  minU = u;
                  minV = v;
               }
            }
         }
         
         // This condition means exp( -||mean[u]-mean[v]||_2 ) < 0.90.
         if( min > 0.0111f )
            break;
         
         merged[minU] = 1;
         merged[minV] = 1;
         mapping[minU] = curLabel;
         mapping[minV] = curLabel;
         
         ++curLabel;
      }
      
      // Finish the mapping.
      for( u = 0; u < prevNlabels; ++u )
      {
         if( merged[u] )
            i[u] = mapping[u];
         else
            i[u] = curLabel++;
         j[u] = u;
         k[u] = 1.0f;
      }
      
      ...
      
      // NOTE: need to update means[] here.
      
      prevNlabels = curLabel;
   }
}