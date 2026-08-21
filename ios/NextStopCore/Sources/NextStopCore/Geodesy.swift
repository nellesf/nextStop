import Foundation

enum Geodesy {
  private static let semiMajorAxisMeters = 6_378_137.0
  private static let flattening = 1.0 / 298.257_223_563
  private static let semiMinorAxisMeters = semiMajorAxisMeters * (1 - flattening)

  static func distanceMeters(from first: Coordinate, to second: Coordinate) -> Double {
    if first == second {
      return 0
    }

    let phi1 = radians(fromDegrees: first.latitude)
    let phi2 = radians(fromDegrees: second.latitude)
    let reducedLatitude1 = atan((1 - flattening) * tan(phi1))
    let reducedLatitude2 = atan((1 - flattening) * tan(phi2))
    let sinU1 = sin(reducedLatitude1)
    let cosU1 = cos(reducedLatitude1)
    let sinU2 = sin(reducedLatitude2)
    let cosU2 = cos(reducedLatitude2)
    let longitudeDifference = radians(fromDegrees: second.longitude - first.longitude)
    var lambda = longitudeDifference

    for _ in 0..<100 {
      let state = vincentyState(
        lambda: lambda,
        sinU1: sinU1,
        cosU1: cosU1,
        sinU2: sinU2,
        cosU2: cosU2
      )
      if state.sinSigma == 0 {
        return 0
      }

      let previousLambda = lambda
      lambda = nextLambda(longitudeDifference: longitudeDifference, state: state)
      if abs(lambda - previousLambda) <= 1e-12 {
        return vincentyDistance(state: state)
      }
    }

    return haversineDistanceMeters(from: first, to: second)
  }

  private struct VincentyState {
    let sinSigma: Double
    let cosSigma: Double
    let sigma: Double
    let sinAlpha: Double
    let cosSquaredAlpha: Double
    let cosDoubleSigmaMidpoint: Double
  }

  private static func vincentyState(
    lambda: Double,
    sinU1: Double,
    cosU1: Double,
    sinU2: Double,
    cosU2: Double
  ) -> VincentyState {
    let sinLambda = sin(lambda)
    let cosLambda = cos(lambda)
    let firstTerm = cosU2 * sinLambda
    let secondTerm = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
    let sinSigma = hypot(firstTerm, secondTerm)
    let cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
    let sigma = atan2(sinSigma, cosSigma)
    let sinAlpha = (cosU1 * cosU2 * sinLambda) / sinSigma
    let cosSquaredAlpha = 1 - sinAlpha * sinAlpha
    let cosDoubleSigmaMidpoint =
      cosSquaredAlpha == 0
      ? 0
      : cosSigma - (2 * sinU1 * sinU2) / cosSquaredAlpha

    return VincentyState(
      sinSigma: sinSigma,
      cosSigma: cosSigma,
      sigma: sigma,
      sinAlpha: sinAlpha,
      cosSquaredAlpha: cosSquaredAlpha,
      cosDoubleSigmaMidpoint: cosDoubleSigmaMidpoint
    )
  }

  private static func nextLambda(
    longitudeDifference: Double,
    state: VincentyState
  ) -> Double {
    let coefficient =
      (flattening / 16) * state.cosSquaredAlpha
      * (4 + flattening * (4 - 3 * state.cosSquaredAlpha))
    return longitudeDifference
      + (1 - coefficient) * flattening * state.sinAlpha
      * (state.sigma
        + coefficient * state.sinSigma
        * (state.cosDoubleSigmaMidpoint
          + coefficient * state.cosSigma
          * (-1 + 2 * state.cosDoubleSigmaMidpoint * state.cosDoubleSigmaMidpoint)))
  }

  private static func vincentyDistance(state: VincentyState) -> Double {
    let squaredU =
      state.cosSquaredAlpha
      * (semiMajorAxisMeters * semiMajorAxisMeters
        - semiMinorAxisMeters * semiMinorAxisMeters)
      / (semiMinorAxisMeters * semiMinorAxisMeters)
    let coefficientA =
      1
      + (squaredU / 16_384)
      * (4096 + squaredU * (-768 + squaredU * (320 - 175 * squaredU)))
    let coefficientB =
      (squaredU / 1024)
      * (256 + squaredU * (-128 + squaredU * (74 - 47 * squaredU)))
    let cosDoubleSigmaMidpointSquared =
      state.cosDoubleSigmaMidpoint * state.cosDoubleSigmaMidpoint
    let sinSigmaSquared = state.sinSigma * state.sinSigma
    let deltaSigma =
      coefficientB * state.sinSigma
      * (state.cosDoubleSigmaMidpoint
        + (coefficientB / 4)
          * (state.cosSigma * (-1 + 2 * cosDoubleSigmaMidpointSquared)
            - (coefficientB / 6) * state.cosDoubleSigmaMidpoint
              * (-3 + 4 * sinSigmaSquared)
              * (-3 + 4 * cosDoubleSigmaMidpointSquared)))
    return semiMinorAxisMeters * coefficientA * (state.sigma - deltaSigma)
  }

  private static func haversineDistanceMeters(
    from first: Coordinate,
    to second: Coordinate
  ) -> Double {
    let latitudeDelta = radians(fromDegrees: second.latitude - first.latitude)
    let longitudeDelta = radians(fromDegrees: second.longitude - first.longitude)
    let firstLatitude = radians(fromDegrees: first.latitude)
    let secondLatitude = radians(fromDegrees: second.latitude)
    let haversine =
      sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(firstLatitude) * cos(secondLatitude)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return 2 * semiMajorAxisMeters * asin(min(1, sqrt(haversine)))
  }

  private static func radians(fromDegrees degrees: Double) -> Double {
    degrees * .pi / 180
  }
}
