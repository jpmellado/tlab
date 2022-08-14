#include "types.h"

module THERMO_VARS
    use TLAB_CONSTANTS, only: MAX_NSP, MAX_PROF

    implicit none
    save

    TREAL :: gama0, GRATIO                  ! Compressibility. Specific heat ratio
    TREAL :: MRATIO                         ! Compressible parameter

    TINTEGER :: imixture
    character*128 :: chemkin_file           ! File with thermodynamic data, if used

    TINTEGER :: NSP                         ! Number of components (species) in a mixture
    character*16, dimension(MAX_NSP) :: THERMO_SPNAME
    TREAL, dimension(MAX_NSP) :: WGHT_INV   ! Inverse of molecular weight, i.e., gas constant

    TINTEGER, parameter :: MAX_NCP = 7      ! Caloric data; cp(T), formation enthalpy, formation entropy
    TINTEGER :: NCP                         ! Number of terms in polynomial fit to cp
    TREAL :: THERMO_AI(MAX_NCP, 2, MAX_NSP) ! Polynomial coefficients. Last to terms are formation enthalpy and formation entropy
    !                                         The second index indicates each of the 2 temperature intervals considered in the fit
    TREAL :: THERMO_TLIM(3, MAX_NSP)        ! Temperature limits of the two temperature intervals in the polynomial fits.

    TREAL :: WMEAN, dsmooth                 ! Inifinitely fast
    TREAL, dimension(MAX_NSP) :: YMASS

    TINTEGER, parameter :: MAX_NPSAT = 10   ! Polynomial fit to saturation pressure
    TINTEGER :: NPSAT
    TREAL :: THERMO_PSAT(MAX_NPSAT), NEWTONRAPHSON_ERROR

    logical nondimensional                  ! Nondimensional formulation
    TREAL :: WREF, TREF, RGAS

    TREAL :: thermo_param(MAX_PROF)         ! Additional data

end module THERMO_VARS