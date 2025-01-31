#pragma once

#include "intersections.h"

// CHECKITOUT
/**
 * Computes a cosine-weighted random direction in a hemisphere.
 * Used for diffuse lighting.
 */
__host__ __device__
glm::vec3 calculateRandomDirectionInHemisphere(
        glm::vec3 normal, thrust::default_random_engine &rng) {
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(1, 0, 0);
    } else if (abs(normal.y) < SQRT_OF_ONE_THIRD) {
        directionNotNormal = glm::vec3(0, 1, 0);
    } else {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

__host__ __device__
glm::vec3 calculateFresnel(const Material &m, float cosTheta) {
    float etaI = 1.0;
    float etaT = m.indexOfRefraction;
    float cosThetaI = glm::clamp(cosThetaI, -1.f, 1.f);
    
    // Check if entering or leaving medium, and swap indices of refraction if necessary
    bool leaving = (cosThetaI < 0.f);
    if (leaving) {
        float tmp = etaI;
        etaI = etaT;
        etaT = tmp;
        cosThetaI = glm::abs(cosThetaI);
    }
    float eta = etaI / etaT;

    // Snell's Law
    float sinThetaI = glm::sqrt(max(0.0, 1.0 - cosThetaI * cosThetaI));
    float sinThetaT = eta * sinThetaI;

    // Total internal reflection
    if (sinThetaT >= 1.0) return glm::vec3(1.0, 1.0, 1.0);

    // Compute Fresnel reflectance (see equation in PBRT 8.2.1)
    float cosThetaT = glm::sqrt(glm::max(0.0, 1.0 - sinThetaT * sinThetaT));
    float rParallel = ((etaT * cosThetaI) - (etaI * cosThetaT)) /
        ((etaT * cosThetaI) + (etaI * cosThetaT));
    float rPerp = ((etaI * cosThetaI) - (etaT * cosThetaT)) /
        ((etaI * cosThetaI) + (etaT * cosThetaT));

    return glm::vec3((rParallel * rParallel + rPerp * rPerp) * 0.5f);
}

__host__ __device__
glm::vec3 sample_diffuse(
    glm::vec3 &normal, const Material& m, thrust::default_random_engine& rng, glm::vec3 wo, glm::vec3& wi) 
{
    wi = calculateRandomDirectionInHemisphere(normal, rng);
    return m.color;
}

__host__ __device__
glm::vec3 sample_specular_refl(
    glm::vec3 &normal, const Material& m, thrust::default_random_engine& rng, glm::vec3 wo, glm::vec3& wi) 
{
    wi = glm::reflect(wo, normal);
    return m.specular.color;
}

__host__ __device__
glm::vec3 sample_specular_trans(
    glm::vec3 &normal, const Material& m, thrust::default_random_engine& rng, glm::vec3 wo, glm::vec3& wi) 
{
    float entering = (glm::dot(wo, normal) < 0);
    float eta = (entering) ? 1.f / m.indexOfRefraction : m.indexOfRefraction;

    // Flip normal to be in same hemisphere as wo
    bool flip = (glm::dot(wo, normal) > 0.f);
    normal = (flip) ? -normal : normal;
    wi = glm::refract(wo, normal, eta);
  
    // Total internal reflection
    if (glm::length(wi) < 0) {
        wi = glm::reflect(wo, normal);
        return glm::vec3(0.0, 0.0, 0.0);
    }
    return m.specular.color;
}

__host__ __device__
glm::vec3 sample_glass(
    glm::vec3& normal, const Material& m, thrust::default_random_engine& rng, glm::vec3 wo, glm::vec3& wi)
{
    thrust::uniform_real_distribution<float> u01(0, 1);
    bool reflect = u01(rng) < 0.5;

    float cosTheta = glm::dot(wo, normal);
    glm::vec3 Fr = calculateFresnel(m, cosTheta);
    glm::vec3 f = glm::vec3(0.0, 0.0, 0.0);
    if (reflect) {
        f = sample_specular_refl(normal, m, rng, wo, wi);
        return 2.f * Fr * f;
    }
    else {
        f = sample_specular_trans(normal, m, rng, wo, wi);
        return 2.f * (glm::vec3(1.f, 1.f, 1.f) - Fr) * f;
    }
}

__host__ __device__
glm::vec3 sample_plastic(
    glm::vec3& normal, const Material& m, thrust::default_random_engine& rng, glm::vec3 wo, glm::vec3& wi)
{
    thrust::uniform_real_distribution<float> u01(0, 1);
    bool reflect = u01(rng) < 0.5;

    float cosTheta = glm::dot(wo, normal);
    glm::vec3 Fr = calculateFresnel(m, cosTheta);
    glm::vec3 f = glm::vec3(0.0, 0.0, 0.0);
    if (reflect) {
        f = sample_specular_refl(normal, m, rng, wo, wi);
        return 2.f * Fr * f;
    }
    else {
        f = sample_diffuse(normal, m, rng, wo, wi);
        return 2.f * (glm::vec3(1.f, 1.f, 1.f) - Fr) * f;
    }
}

/**
 * Scatter a ray with some probabilities according to the material properties.
 * For example, a diffuse surface scatters in a cosine-weighted hemisphere.
 * A perfect specular surface scatters in the reflected ray direction.
 * In order to apply multiple effects to one surface, probabilistically choose
 * between them.
 *
 * The visual effect you want is to straight-up add the diffuse and specular
 * components. You can do this in a few ways. This logic also applies to
 * combining other types of materias (such as refractive).
 *
 * - Always take an even (50/50) split between a each effect (a diffuse bounce
 *   and a specular bounce), but divide the resulting color of either branch
 *   by its probability (0.5), to counteract the chance (0.5) of the branch
 *   being taken.
 *   - This way is inefficient, but serves as a good starting point - it
 *     converges slowly, especially for pure-diffuse or pure-specular.
 * - Pick the split based on the intensity of each material color, and divide
 *   branch result by that branch's probability (whatever probability you use).
 *
 * This method applies its changes to the Ray parameter `ray` in place.
 * It also modifies the color `color` of the ray in place.
 *
 * You may need to change the parameter list for your purposes!
 */
__host__ __device__
void scatterRay(
        PathSegment & pathSegment,
        glm::vec3 intersect,
        glm::vec3 normal,
        const Material &m,
        thrust::default_random_engine &rng) {
    // TODO: implement this.
    // A basic implementation of pure-diffuse shading will just call the
    // calculateRandomDirectionInHemisphere defined above.
    if (pathSegment.remainingBounces <= 0) {
        return;
    }
    thrust::uniform_real_distribution<float> u01(0, 1);
    float xi = u01(rng);

    glm::vec3 wi = glm::vec3(0.0, 0.0, 0.0);
    glm::vec3 f = glm::vec3(0.0, 0.0, 0.0);
    if (m.hasReflective && m.hasRefractive) {
        f = sample_glass(normal, m, rng, pathSegment.ray.direction, wi);
    }
    else if (m.hasReflective && glm::length(m.color) > 0) {
        f = sample_plastic(normal, m, rng, pathSegment.ray.direction, wi);
    }
    else if (m.hasReflective) {
        f = sample_specular_refl(normal, m, rng, pathSegment.ray.direction, wi);
    }
    else if (m.hasRefractive) {
        f = sample_specular_trans(normal, m, rng, pathSegment.ray.direction, wi);
    }
    else {
        f = sample_diffuse(normal, m, rng, pathSegment.ray.direction, wi);
    }
    pathSegment.throughput *= f;
    pathSegment.ray.direction = wi;
    pathSegment.ray.invDirection = glm::vec3(1.0, 1.0, 1.0) / pathSegment.ray.direction;
    pathSegment.ray.origin = intersect + 0.01f * pathSegment.ray.direction;
    pathSegment.remainingBounces--;
}
