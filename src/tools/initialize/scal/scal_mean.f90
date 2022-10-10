#include "dns_const.h"

subroutine SCAL_MEAN(is, s, wrk1d, wrk2d, wrk3d)

    use TLAB_TYPES, only: wp, wi
    use TLAB_VARS, only: g
    use TLAB_VARS, only: imax, jmax, kmax
    use TLAB_VARS, only: imode_sim
    use TLAB_VARS, only: pbg, rbg, tbg, sbg, qbg
    use PROFILES
    implicit none

    integer(wi) is
    real(wp), intent(OUT) :: s(imax, jmax, kmax)
    real(wp), intent(INOUT) :: wrk3d(*)
    real(wp), intent(INOUT) :: wrk2d(imax, jmax, *)
    real(wp), intent(INOUT) :: wrk1d(jmax, *)

    ! -------------------------------------------------------------------
    integer(wi) j, k
    real(wp) dummy

    !########################################################################
    if (imode_sim == DNS_MODE_TEMPORAL) then
        do j = 1, jmax
            dummy = PROFILES_CALCULATE(sbg(is), g(2)%nodes(j))
            s(:, j, :) = dummy + s(:, j, :)
        end do

    else if (imode_sim == DNS_MODE_SPATIAL .and. rbg%type == PROFILE_NONE) then ! temperature/mixture profile are given
#define rho_vi(j) wrk1d(j,1)
#define u_vi(j)   wrk1d(j,2)
#define z_vi(j)   wrk1d(j,3)
#define aux1(j)   wrk1d(j,4)
#define aux2(j)   wrk1d(j,5)
#define aux3(j)   wrk1d(j,6)
#define aux4(j)   wrk1d(j,7)
#define rho_loc(i,j) wrk2d(i,j,1)
#define p_loc(i,j)   wrk2d(i,j,2)
#define u_loc(i,j)   wrk2d(i,j,3)
#define v_loc(i,j)   wrk2d(i,j,4)
#define t_loc(i,j)   wrk2d(i,j,5)
        ! Inflow profile of scalar
        do j = 1, jmax
            z_vi(j) = PROFILES_CALCULATE(sbg(is), g(2)%nodes(j))
        end do

        ! Initialize density field
        rho_vi(1:jmax) = 0.0_wp
        do j = 1, jmax
            dummy = PROFILES_CALCULATE(tbg, g(2)%nodes(j))
            ! pilot to be added: ijet_pilot, rjet_pilot_thickness, XIST
            t_loc(:, j) = dummy
        end do
        ! the species array here is wrong for multispecies case !!!
        p_loc(:, :) = pbg%mean
        call THERMO_THERMAL_DENSITY(imax, jmax, 1, s, p_loc(1, 1), t_loc(1, 1), rho_loc(1, 1))

        ! Inflow profile of density
        rho_vi(:) = rho_loc(1, :)

        ! inflow profile of velocity
        u_vi(1:jmax) = 0.0_wp
        do j = 1, jmax
            u_vi(j) = PROFILES_CALCULATE(qbg(1), g(2)%nodes(j))
            ! pilot to be added: ijet_pilot, rjet_pilot_thickness, rjet_pilot_velocity
        end do

        ! 2D distributions of density and velocity
        if (rbg%delta /= 0.0_wp) then
            call FLOW_SPATIAL_DENSITY(imax, jmax, tbg, qbg(1), &
                                   g(1)%nodes, g(2)%nodes, s, p_loc(1, 1), rho_vi(1), u_vi(1), aux1(1), rho_loc(1, 1), &
                                      aux2(1), aux3(1), aux4(1))
        end if
        call FLOW_SPATIAL_VELOCITY(imax, jmax, qbg(1), qbg(1)%diam,  &
                                   qbg(1)%parameters(2), qbg(1)%parameters(3), qbg(1)%parameters(4), &
                                g(1)%nodes, g(2)%nodes, rho_vi(1), u_vi(1), rho_loc(1, 1), u_loc(1, 1), v_loc(1, 1), aux1(1), wrk3d)
        ! 2D distribution of scalar
        call FLOW_SPATIAL_SCALAR(imax, jmax, sbg(is), sbg(is)%diam, sbg(is)%diam,  &
                                 sbg(is)%parameters(2), sbg(is)%parameters(3), sbg(is)%parameters(4), &
                                 g(1)%nodes, g(2)%nodes, rho_vi(1), u_vi(1), z_vi(1), rho_loc(1, 1), u_loc(1, 1), s, wrk3d)
        if (g(3)%size > 1) then
            do k = 2, kmax
                s(:, :, k) = s(:, :, 1)
            end do
        end if

    end if

    return
end subroutine SCAL_MEAN
