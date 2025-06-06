#include "dns_const.h"

program VEFILTER
    use TLab_Constants, only: wp, wi, pi_wp
    use FDM, only: fdm_dt, FDM_CreatePlan
    use FDM_Derivative, only: FDM_COM6_JACOBIAN
    use NavierStokes, only: visc, schmidt
    use FLT_Base
    use OPR_FILTERS

    implicit none

    integer(wi) imax, i, ik, i1bc
    parameter(imax=257)
    real(wp), allocatable :: x(:, :)
    real(wp) u(imax), uf(imax)
    real(wp) wrk1d(imax, 18)! , wrk2d(imax), wrk3d(imax) YOU NEED TO USE NEW MEM MANAGEMENT
    type(filter_dt) filter
    type(fdm_dt) g

! ###################################################################
    g%size = imax
    g%scale = 2.0_wp*pi_wp
    g%der1%mode_fdm = FDM_COM6_JACOBIAN
    visc = 1.0_wp
    schmidt = 1.0_wp

    write (*, *) 'Periodic (0) or nonperiodic (1) case ?'
    read (*, *) i1bc

    if (i1bc == 0) then
        g%periodic = .true.
        g%uniform = .true.
        filter%bcsmin = DNS_FILTER_BCS_PERIODIC
        filter%bcsmax = DNS_FILTER_BCS_PERIODIC
        do i = 1, imax
            wrk1d(i, 1) = real(i - 1)/real(imax)*g%scale
            ! x(i, 1) = real(i - 1)/real(imax)*g%scale
        end do
    else
        g%periodic = .false.
        g%uniform = .false.
        filter%bcsmin = DNS_FILTER_BCS_ZERO
        filter%bcsmax = DNS_FILTER_BCS_ZERO
        do i = 1, imax
            wrk1d(i, 1) = real(i - 1)/real(imax - 1)*g%scale
            ! x(i, 1) = real(i - 1)/real(imax-1)*g%scale
        end do
        ! open (21, file='y.dat')
        ! do i = 1, imax
        !     read (21, *) x(i, 1)
        ! end do
        ! close (21)
        ! g%scale = x(imax, 1) - x(1, 1)
    end if

    call FDM_CreatePlan(wrk1d(1:imax, 1), g)

    ! ###################################################################

    ! Define the function
    ! if (i1bc == 0) then
    write (*, *) 'Wavenumber ?'
    read (*, *) ik
    u(:) = sin(2.0_wp*pi_wp/g%scale*real(ik)*x(:, 1))
    ! else
    !     open (21, file='f.dat')
    !     do i = 1, imax
    !         read (21, *) u(i)
    !         uf(i) = u(i)
    !     end do
    !     close (21)
    ! end if

! ###################################################################
    filter%size = g%size
    filter%periodic = g%periodic
    ! filter%type = DNS_FILTER_COMPACT_CUTOFF
    ! filter%inb_filter = 7
    filter%type = DNS_FILTER_COMPACT
    filter%inb_filter = 10
    filter%parameters(1) = 0.49

    call OPR_FILTER_INITIALIZE(g, filter)

    call OPR_FILTER_1D(1, filter, u, uf)
    ! call FDM_Der1_Solve(1, [0,0],g%der1, g%der1%lu, u, uf, wrk2d)

    open (20, file='filter.dat')
    do i = 1, imax
        write (20, *) x(i, 1), u(i), uf(i)
    end do
    close (20)

    open (20, file='transfer.dat')
    ! do ik = 1, imax/2
    do ik = 1, (imax - 1)/2
        u = sin(2.0_wp*pi_wp/g%scale*real(ik)*x(:, 1))
        call OPR_FILTER_1D(1, filter, u, uf)
        ! call FDM_Der1_Solve(1, [0,0], g%der1, g%der1%lu, u, uf, wrk2d)
        write (20, *) ik, maxval(uf)
    end do
    close (20)

    stop
end program VEFILTER
