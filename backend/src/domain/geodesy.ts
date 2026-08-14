const semiMajorAxisMeters = 6_378_137;
const flattening = 1 / 298.257_223_563;
const semiMinorAxisMeters = semiMajorAxisMeters * (1 - flattening);
const firstEccentricitySquared = flattening * (2 - flattening);

export interface GeographicCoordinate {
  readonly latitude: number;
  readonly longitude: number;
}

export interface EarthCenteredCoordinate {
  readonly x: number;
  readonly y: number;
  readonly z: number;
}

export function geodesicDistanceMeters(
  first: GeographicCoordinate,
  second: GeographicCoordinate,
): number {
  if (first.latitude === second.latitude && first.longitude === second.longitude) {
    return 0;
  }

  const phi1 = toRadians(first.latitude);
  const phi2 = toRadians(second.latitude);
  const reducedLatitude1 = Math.atan((1 - flattening) * Math.tan(phi1));
  const reducedLatitude2 = Math.atan((1 - flattening) * Math.tan(phi2));
  const sinU1 = Math.sin(reducedLatitude1);
  const cosU1 = Math.cos(reducedLatitude1);
  const sinU2 = Math.sin(reducedLatitude2);
  const cosU2 = Math.cos(reducedLatitude2);
  const longitudeDifference = toRadians(second.longitude - first.longitude);
  let lambda = longitudeDifference;
  let state: VincentyState | undefined;

  for (let iteration = 0; iteration < 100; iteration += 1) {
    state = calculateVincentyState(lambda, sinU1, cosU1, sinU2, cosU2);
    if (state.sinSigma === 0) {
      return 0;
    }
    const previousLambda = lambda;
    lambda = nextLambda(longitudeDifference, state);
    if (Math.abs(lambda - previousLambda) <= 1e-12) {
      return vincentyDistance(state);
    }
  }

  return haversineDistanceMeters(first, second);
}

export function earthCenteredCoordinate(
  coordinate: GeographicCoordinate,
): EarthCenteredCoordinate {
  const latitude = toRadians(coordinate.latitude);
  const longitude = toRadians(coordinate.longitude);
  const sinLatitude = Math.sin(latitude);
  const cosLatitude = Math.cos(latitude);
  const primeVerticalRadius =
    semiMajorAxisMeters /
    Math.sqrt(1 - firstEccentricitySquared * sinLatitude * sinLatitude);

  return {
    x: primeVerticalRadius * cosLatitude * Math.cos(longitude),
    y: primeVerticalRadius * cosLatitude * Math.sin(longitude),
    z:
      primeVerticalRadius *
      (1 - firstEccentricitySquared) *
      sinLatitude,
  };
}

interface VincentyState {
  readonly sinSigma: number;
  readonly cosSigma: number;
  readonly sigma: number;
  readonly sinAlpha: number;
  readonly cosSquaredAlpha: number;
  readonly cosDoubleSigmaMidpoint: number;
}

function calculateVincentyState(
  lambda: number,
  sinU1: number,
  cosU1: number,
  sinU2: number,
  cosU2: number,
): VincentyState {
  const sinLambda = Math.sin(lambda);
  const cosLambda = Math.cos(lambda);
  const firstTerm = cosU2 * sinLambda;
  const secondTerm = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda;
  const sinSigma = Math.hypot(firstTerm, secondTerm);
  const cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
  const sigma = Math.atan2(sinSigma, cosSigma);
  const sinAlpha = (cosU1 * cosU2 * sinLambda) / sinSigma;
  const cosSquaredAlpha = 1 - sinAlpha * sinAlpha;
  const cosDoubleSigmaMidpoint =
    cosSquaredAlpha === 0
      ? 0
      : cosSigma - (2 * sinU1 * sinU2) / cosSquaredAlpha;
  return {
    sinSigma,
    cosSigma,
    sigma,
    sinAlpha,
    cosSquaredAlpha,
    cosDoubleSigmaMidpoint,
  };
}

function nextLambda(
  longitudeDifference: number,
  state: VincentyState,
): number {
  const coefficient =
    (flattening / 16) *
    state.cosSquaredAlpha *
    (4 + flattening * (4 - 3 * state.cosSquaredAlpha));
  return (
    longitudeDifference +
    (1 - coefficient) *
      flattening *
      state.sinAlpha *
      (state.sigma +
        coefficient *
          state.sinSigma *
          (state.cosDoubleSigmaMidpoint +
            coefficient *
              state.cosSigma *
              (-1 + 2 * state.cosDoubleSigmaMidpoint ** 2)))
  );
}

function vincentyDistance(state: VincentyState): number {
  const squaredU =
    (state.cosSquaredAlpha *
      (semiMajorAxisMeters ** 2 - semiMinorAxisMeters ** 2)) /
    semiMinorAxisMeters ** 2;
  const coefficientA =
    1 +
    (squaredU / 16_384) *
      (4096 + squaredU * (-768 + squaredU * (320 - 175 * squaredU)));
  const coefficientB =
    (squaredU / 1024) *
    (256 + squaredU * (-128 + squaredU * (74 - 47 * squaredU)));
  const deltaSigma =
    coefficientB *
    state.sinSigma *
    (state.cosDoubleSigmaMidpoint +
      (coefficientB / 4) *
        (state.cosSigma * (-1 + 2 * state.cosDoubleSigmaMidpoint ** 2) -
          (coefficientB / 6) *
            state.cosDoubleSigmaMidpoint *
            (-3 + 4 * state.sinSigma ** 2) *
            (-3 + 4 * state.cosDoubleSigmaMidpoint ** 2)));
  return semiMinorAxisMeters * coefficientA * (state.sigma - deltaSigma);
}

function haversineDistanceMeters(
  first: GeographicCoordinate,
  second: GeographicCoordinate,
): number {
  const latitudeDelta = toRadians(second.latitude - first.latitude);
  const longitudeDelta = toRadians(second.longitude - first.longitude);
  const firstLatitude = toRadians(first.latitude);
  const secondLatitude = toRadians(second.latitude);
  const haversine =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(firstLatitude) *
      Math.cos(secondLatitude) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 2 * semiMajorAxisMeters * Math.asin(Math.min(1, Math.sqrt(haversine)));
}

function toRadians(degrees: number): number {
  return (degrees * Math.PI) / 180;
}
