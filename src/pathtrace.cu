#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>
#include <thrust/partition.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

// Turn on anti-aliasing to removed jagged edges on shapes
#define ANTIALIASING

// Turn on to sort by material (keeps same materials contiguous in memory)
//#define MATERIAL_SORT

// Turn on to stream compact
#define STREAM_COMPACTION

// Turn off cache first bouncing when anti-aliasing is enabled
#ifndef ANTIALIASING
	#define CACHE_FIRST_BOUNCE
#endif

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

// Returns true if a path still has bounces left
struct not_zero
{
	__host__ __device__
		bool operator()(const PathSegment &path)
	{
		return path.remainingBounces != 0;
	}
};

// Compares the material ids of two materials to sort them in ascending order
struct mat_id
{
	__host__ __device__
		bool operator()(const ShadeableIntersection &i1, ShadeableIntersection & i2)
	{
		return i1.materialId < i2.materialId;
	}
};

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

// Color correction helper functions (to convert to sRGB)
__host__ __device__ glm::vec3 reinhardOp(glm::vec3 c) {
	return c / (glm::vec3(1.f, 1.f, 1.f) + c);
}

__host__ __device__ glm::vec3 gammaCorrect(glm::vec3 c) {
	glm::vec3 gamma = glm::vec3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2);
	return pow(c, gamma);
}

// Use a cosine-based color palette to map intersection count to color - from "Color Palettes" - Inigo Quilez
__host__ __device__ glm::vec3 palette(glm::vec3 a, glm::vec3 b, glm::vec3 c, glm::vec3 d, float t) {
	return a + b * cos(6.28318f * (c * t + d));
}

__host__ __device__ glm::vec3 intToColor(float count) {
	// Map value to [0, 1] range
	float val = count * (1.f / 250.f);
	return palette(glm::vec3(0.5f, 0.5f, 0.5f), glm::vec3(0.5f, 0.5f, 0.5f), glm::vec3(1.f, 0.7f, 0.4f), glm::vec3(0.f, 0.15f, 0.2f), val);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		// Average samples
		glm::vec3 mod_color = pix / glm::vec3(iter, iter, iter);

#if CONVERT_TO_SRGB
		// Apply Reinhard operator 
		mod_color = reinhardOp(mod_color);

		// Apply gamma correction
		mod_color = gammaCorrect(mod_color);
#endif

		// Convert to 0-255 scale
		glm::ivec3 color;
		color.x = glm::clamp((int)(mod_color.x * 255.0), 0, 255);
		color.y = glm::clamp((int)(mod_color.y * 255.0), 0, 255);
		color.z = glm::clamp((int)(mod_color.z * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static LBVHNode* dev_lbvh = NULL;
static BVHNode* dev_bvh = NULL;
static Triangle* dev_tris = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;

// For saving first-bounce intersections
static ShadeableIntersection* dev_first_bounce_intersections = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_lbvh, scene->lbvh.size() * sizeof(LBVHNode));
	cudaMemcpy(dev_lbvh, scene->lbvh.data(), scene->lbvh.size() * sizeof(LBVHNode), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_bvh, scene->bvh.size() * sizeof(BVHNode));
	cudaMemcpy(dev_bvh, scene->bvh.data(), scene->bvh.size() * sizeof(BVHNode), cudaMemcpyHostToDevice);
	
	cudaMalloc(&dev_tris, scene->triangles.size() * sizeof(Triangle));
	cudaMemcpy(dev_tris, scene->triangles.data(), scene->triangles.size() * sizeof(Triangle), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_first_bounce_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_first_bounce_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_lbvh);
	cudaFree(dev_bvh);
	cudaFree(dev_tris);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_first_bounce_intersections);

	checkCUDAError("pathtraceFree");
}

/**
* Concentric Disk Sampling from PBRT Chapter 13.6.2
*/
__host__ __device__ glm::vec3 concentricSampleDisk(glm::vec2 &sample)
{
	// Map sample point (uniform random numbers) to range [-1, 1]
	glm::vec2 mappedSample = 2.f * sample - glm::vec2(1.f, 1.f);

	// Handle origin to avoid divide by zero
	if (mappedSample.x == 0.f && mappedSample.y == 0.f) {
		return glm::vec3(0.f);
	}

	// Apply concentric mapping to the adjusted sample point
	float r = 0.f;
	float theta = 0.f;
	// Find r and theta depending on x and y coords of mapped point
	if (std::abs(mappedSample.x) > std::abs(mappedSample.y)) {
		r = mappedSample.x;
		theta = PI_OVER_FOUR * (mappedSample.y / mappedSample.x);
	}
	else {
		r = mappedSample.y;
		theta = PI_OVER_TWO - PI_OVER_FOUR * (mappedSample.x / mappedSample.y);
	}

	return glm::vec3(r * cos(theta), r * sin(theta), 0);
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	// Add jitter to x and y
	thrust::default_random_engine rng = makeSeededRandomEngine(iter, x + y * cam.resolution.x, 0);
	thrust::uniform_real_distribution<float> u01(0, 1);
	float jitterX = 0.0;
	float jitterY = 0.0;
#ifdef ANTIALIASING
	jitterX = u01(rng);
	jitterY = u01(rng);
#endif 

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(0.0f, 0.0f, 0.0f);
		segment.throughput = glm::vec3(1.0f, 1.0f, 1.0f);

		// Jitter the ray for anti-aliasing
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)(x + jitterX) - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)(y + jitterY) - (float)cam.resolution.y * 0.5f)
		);

		// Depth-of-field (if specified in scene file)
		if (cam.lens_radius > 0.0f) {
			// Get sample on lens
			glm::vec3 samplePoint = cam.lens_radius * concentricSampleDisk(glm::vec2(u01(rng), u01(rng)));

			// Focal point
			float ft = glm::length(cam.lookAt - cam.position);
			glm::vec3 focalPoint = getPointOnRay(segment.ray, ft);

			// Update ray
			segment.ray.origin += samplePoint;
			segment.ray.direction = glm::normalize(focalPoint - segment.ray.origin);
		}
		segment.ray.invDirection = glm::vec3(1.0, 1.0, 1.0) / segment.ray.direction;
		segment.ray.intersectionCount = 0.f;
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, LBVHNode* dev_lbvh
	, BVHNode* dev_bvh
	, Triangle* dev_tris
	, int geoms_size
	, ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment &pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms
		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?
			else if (geom.type == MESH)
			{
#if USE_LBVH
				t = lbvhIntersectionTest(dev_lbvh, dev_tris, pathSegment.ray, geom.triangleCount, tmp_intersect, tmp_normal, outside);
#elif USE_BVH
				t = bvhIntersectionTest(dev_bvh, dev_tris, pathSegment.ray, geom.triangleCount, tmp_intersect, tmp_normal, outside);
#else
				t = meshIntersectionTest(geom, pathSegment.ray, dev_tris, tmp_intersect, tmp_normal, outside);
#endif
			}
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

__global__ void shadeAllMaterials(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		//if (pathSegments[idx].remainingBounces <= 0)
		//{
		//	return;
		//}
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, pathSegments[idx].remainingBounces);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color += (materialColor * material.emittance) * pathSegments[idx].throughput;
				pathSegments[idx].remainingBounces = 0;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				scatterRay(pathSegments[idx], getPointOnRay(pathSegments[idx].ray, intersection.t),
					intersection.surfaceNormal, material, rng);
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.

#if RUSSIAN_ROULETTE
			if (iter > 3) {
				float maxColorChannel = glm::max(pathSegments[idx].throughput.r, glm::max(pathSegments[idx].throughput.g, pathSegments[idx].throughput.b));
				float xi = u01(rng);
				if (xi < (1.f - maxColorChannel)) {
					pathSegments[idx].remainingBounces = 0;
				}
				else {
					pathSegments[idx].throughput /= maxColorChannel;
				}
			}
#endif
		}
		else {
			pathSegments[idx].remainingBounces = 0;
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
#if DISPLAY_HEATMAP
		image[iterationPath.pixelIndex] += intToColor(iterationPath.ray.intersectionCount);
#else
		image[iterationPath.pixelIndex] += iterationPath.color;
#endif
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int compact_num_paths = num_paths;
	thrust::device_ptr<PathSegment> dev_thrust_paths = thrust::device_pointer_cast(dev_paths);

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, compact_num_paths * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (compact_num_paths + blockSize1d - 1) / blockSize1d;

#ifdef CACHE_FIRST_BOUNCE
		// If first iteration, compute first bounce intersections
		if (iter == 1) {
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, compact_num_paths
				, dev_paths
				, dev_geoms
				, dev_lbvh
				, dev_bvh
				, dev_tris
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
			if (depth == 0) {
				cudaMemcpy(dev_first_bounce_intersections, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
		}
		// For all subsequent iterations, read from cached first bounce intersections 
		else {
			if (depth == 0) {
				cudaMemcpy(dev_intersections, dev_first_bounce_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
			else {
				computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, compact_num_paths
					, dev_paths
					, dev_geoms
					, dev_lbvh
					, dev_bvh
					, dev_tris
					, hst_scene->geoms.size()
					, dev_intersections
					);
				checkCUDAError("trace one bounce");
				cudaDeviceSynchronize();
			}
		}
#else
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, compact_num_paths
			, dev_paths
			, dev_geoms
			, dev_lbvh
			, dev_bvh
			, dev_tris
			, hst_scene->geoms.size()
			, dev_intersections
			);
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();
#endif
		depth++;

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	    // evaluating the BSDF.
	    // Start off with just a big kernel that handles all the different
	    // materials you have in the scenefile.
	    // TODO: compare between directly shading the path segments and shading
	    // path segments that have been reshuffled to be contiguous in memory.

#ifdef MATERIAL_SORT
		// Shuffle paths to be contiguous in memory
		thrust::device_ptr<ShadeableIntersection> dev_thrust_intersections = thrust::device_pointer_cast(dev_intersections);
		thrust::sort_by_key(dev_thrust_intersections, dev_thrust_intersections + compact_num_paths, dev_thrust_paths, mat_id());
#endif

		shadeAllMaterials << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			compact_num_paths,
			dev_intersections,
			dev_paths,
			dev_materials
			);

		// Stream compact
#ifdef STREAM_COMPACTION
		thrust::device_ptr<PathSegment> dev_thrust_path_end = thrust::stable_partition(dev_thrust_paths, dev_thrust_paths + compact_num_paths, not_zero());
		dev_path_end = dev_thrust_path_end.get();
		compact_num_paths = dev_path_end - dev_paths;
#endif

		// TODO: should be based off stream compaction results
		if (depth == traceDepth || dev_paths == dev_path_end) { iterationComplete = true; }

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
