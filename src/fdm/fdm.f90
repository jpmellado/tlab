#include "dns_error.h"

module FDM
    use TLab_Constants, only: wp, wi, pi_wp, roundoff_wp, efile, wfile
    use TLab_Constants, only: BCS_DD, BCS_ND, BCS_DN, BCS_NN, BCS_MIN, BCS_MAX
    use TLab_WorkFlow, only: TLab_Write_ASCII, TLab_Stop, stagger_on
    ! use TLab_Memory, only: TLab_Allocate_Real
    use FDM_PROCS, only: FDM_Bcs_Neumann
    use FDM_MatMul
    use FDM_ComX_Direct
    use FDM_Com1_Jacobian
    use FDM_Com2_Jacobian
    use FDM_Com0_Jacobian
    use FDM_Integral
    implicit none
    private

    type, public :: fdm_dt
        sequence
        character*8 name
        integer(wi) size
        logical :: uniform = .false.
        logical :: periodic = .false.
        real(wp) scale
        real(wp), pointer :: memory(:, :)       ! memory space
        !
        real(wp), pointer :: nodes(:)
        real(wp), pointer :: jac(:, :)          ! pointer to Jacobians
        !
        integer mode_fdm1                       ! finite-difference method for 1. order derivative
        integer nb_diag_1(2)                    ! # of left and right diagonals 1. order derivative (max 5/7)
        real(wp) :: rhs1_b(4, 7), rhs1_t(4, 7)  ! RHS data for Neumann boundary conditions, 1. order derivative max. # of diagonals is 7, # rows is 7/2+1
        real(wp), pointer :: lhs1(:, :)         ! pointer to LHS for 1. derivative
        real(wp), pointer :: rhs1(:, :)         ! pointer to RHS for 1. derivative
        real(wp), pointer :: mwn1(:)            ! pointer to modified wavenumbers
        real(wp), pointer :: lu1(:, :)          ! pointer to LU decomposition for 1. derivative
        !
        real(wp), pointer :: lu0i(:, :)                 ! pointer to LU decomposition for interpolation
        real(wp), pointer :: lu1i(:, :)                 ! pointer to LU decomposition for 1. derivative inc. interp.
        !
        integer mode_fdm2                   ! finite-difference method for 2. order derivative
        integer nb_diag_2(2)                ! # of left and right diagonals 2. order derivative (max 5/7)
        real(wp), pointer :: lhs2(:, :)     ! pointer to LHS for 2. derivative
        real(wp), pointer :: rhs2(:, :)     ! pointer to RHS for 2. derivative
        real(wp), pointer :: mwn2(:)        ! pointer to modified wavenumbers
        real(wp), pointer :: lu2(:, :)      ! pointer to LU decomposition for 2. derivative
        logical :: need_1der = .false.      ! In Jacobian formulation, I need 1. order derivative for the 2. order if non-uniform

    end type fdm_dt

    type(fdm_dt), public :: g(3)                ! Grid information along 3 directions

    public :: FDM_Initialize
    public :: FDM_Der1_Solve
    public :: FDM_Der2_Solve
    public :: FDM_Interpol, FDM_Interpol_Der1

    integer, parameter, public :: FDM_COM4_JACOBIAN = 4
    integer, parameter, public :: FDM_COM6_JACOBIAN_PENTA = 5
    integer, parameter, public :: FDM_COM6_JACOBIAN = 6
    integer, parameter, public :: FDM_COM6_JACOBIAN_HYPER = 7
    integer, parameter, public :: FDM_COM8_JACOBIAN = 8

    integer, parameter, public :: FDM_COM6_DIRECT = 16
    integer, parameter, public :: FDM_COM4_DIRECT = 17

contains
    ! ###################################################################
    ! ###################################################################
    subroutine FDM_Initialize(nodes, g, fdmi, locScale)
        real(wp), intent(in) :: nodes(:)                            ! positions of the grid nodes
        type(fdm_dt), intent(inout) :: g                            ! fdm plan for derivatives
        type(fdm_integral_dt), intent(out), optional :: fdmi(2)     ! fdm plan for integrals
        real(wp), intent(in), optional :: locScale                  ! for consistency check

        ! -------------------------------------------------------------------
        integer(wi) i, ib, ip, ig, nx, ndl, ndr, inb_grid
        integer(wi) nmin, nmax, nsize, bcs_cases(4)

        integer, parameter :: i1 = 1
        logical :: periodic_aux

        ! ###################################################################
        ! Consistency check
        ! ###################################################################
        if (g%periodic .and. g%mode_fdm1 == FDM_COM4_DIRECT) g%mode_fdm1 = FDM_COM4_JACOBIAN        ! they are the same for uniform grids.
        if (g%periodic .and. g%mode_fdm1 == FDM_COM6_DIRECT) g%mode_fdm1 = FDM_COM6_JACOBIAN        ! they are the same for uniform grids.
        if (g%periodic .and. g%mode_fdm2 == FDM_COM4_DIRECT) g%mode_fdm2 = FDM_COM4_JACOBIAN        ! they are the same for uniform grids.
        if (g%periodic .and. g%mode_fdm2 == FDM_COM6_DIRECT) g%mode_fdm2 = FDM_COM6_JACOBIAN_HYPER  ! they are the same for uniform grids.

        g%size = size(nodes)

        if (g%size > 1) then
            g%scale = nodes(g%size) - nodes(1)
            if (g%periodic) g%scale = g%scale*(1.0_wp + 1.0_wp/real(g%size - 1, wp))
        else
            g%scale = 1.0_wp  ! to avoid conditionals and NaN in some of the calculations below
        end if

        if (present(locScale)) then
! print *, abs((scale_loc - g%scale)/scale_loc)
            if (abs((locScale - g%scale)/g%scale) > roundoff_wp) then
                call TLab_Write_ASCII(efile, __FILE__//'. Unmatched domain scale.')
                call TLab_Stop(DNS_ERROR_OPTION)
            end if
        end if

        ! ###################################################################
        ! Memory allocation
        ! ###################################################################
        inb_grid = 1                            ! Nodes

        inb_grid = inb_grid + 1                 ! I need 1 aux array to calculate the Jacobian for 2. order derivative. To be removed.

        inb_grid = inb_grid &                   ! 1. order derivative
                   + 1 &                        ! Jacobian
                   + 5 &                        ! max # of diagonals in LHS
                   + 7                          ! max # of diagonals in RHS
        if (g%periodic) inb_grid = inb_grid + 1 ! modified wavenumber

        if (g%periodic) then
            inb_grid = inb_grid &
                       + 5 + 2                  ! LU decomposition 1. order
        else
            inb_grid = inb_grid &
                       + 5*4                    ! LU decomposition 1. order, 4 bcs
        end if

        inb_grid = inb_grid &                   ! 2. order derivative
                   + 1 &                        ! Jacobian
                   + 5 &                        ! max # of diagonals in LHS
                   + 7 + 5                      ! max # of diagonals in RHS
        if (g%periodic) inb_grid = inb_grid + 1 ! modified wavenumber

        if (g%periodic) then
            inb_grid = inb_grid &
                       + 5 + 2                  ! LU decomposition 2. order
        else
            inb_grid = inb_grid &
                       + 5                      ! LU decomposition 2. order, 1 bcs
        end if

        if (stagger_on .and. g%periodic) then
            inb_grid = inb_grid &
                       + 5 &                    ! LU decomposition interpolation
                       + 5                      ! LU decomposition 1. order with interpolation
        end if

        ! call TLab_Allocate_Real(__FILE__, g%memory, [g%size, inb_grid], g%name)
        allocate (g%memory(g%size, inb_grid))

        ! ###################################################################
        ! ###################################################################
        nx = g%size                     ! node number, for clarity below

        ig = 1                          ! Initialize counter to define pointers inside array x

        ! ###################################################################
        ! Space for node positions
        ! ###################################################################
        g%nodes => g%memory(:, ig)      ! Define pointer inside memory space

        ig = ig + 1                     ! Advance counter

        ! ###################################################################
        ! Space for Jacobians
        ! ###################################################################
        g%jac => g%memory(:, ig:)

        if (nx == 1) then
            g%jac(:, :) = 1.0_wp
            return
        end if

        ig = ig + 2

        ig = ig + 1         ! I need 1 aux array to calculate the Jacobian for 2. order derivative. To be removed.

        ! ###################################################################
        ! first-order derivative
        ! ###################################################################
        g%lhs1 => g%memory(:, ig:)
        ig = ig + 5
        g%rhs1 => g%memory(:, ig:)
        ig = ig + 7

        ! -------------------------------------------------------------------
        ! uniform grid to calculate Jacobian (used for the stencils below and also as grid spacing in the code).
        g%nodes(:) = [(real(i - 1, wp), i=1, g%size)]
        g%jac(:, 1) = 1.0_wp

        call FDM_Der1_CreateSystem(g, periodic=.false.)

        ! LU decomposition
        select case (g%nb_diag_1(1))
        case (3)
            call TRIDFS(nx, g%lhs1(:, 1), g%lhs1(:, 2), g%lhs1(:, 3))
        case (5)
            call PENTADFS2(nx, g%lhs1(:, 1), g%lhs1(:, 2), g%lhs1(:, 3), g%lhs1(:, 4), g%lhs1(:, 5))
        end select

        ! Calculating derivative dxds into g%jac(:, 1)
        periodic_aux = g%periodic
        g%periodic = .false.
        call FDM_Der1_Solve(1, [0, 0], g, g%lhs1, nodes, g%jac(:, 1), g%jac(:, 2)) !g%jac(:, 2) is used as aux array...
        g%periodic = periodic_aux

        ! -------------------------------------------------------------------
        ! Actual grid; possibly nonuniform
        g%nodes(:) = nodes(1:nx)

        if (g%periodic) then                                        ! modified wavenumber
            g%mwn1 => g%memory(:, ig)
            ig = ig + 1
        end if

        call FDM_Der1_CreateSystem(g, g%periodic)

        if (g%periodic) g%mwn1(:) = g%mwn1(:)/g%jac(1, 1)           ! normalized by dx

        ! -------------------------------------------------------------------
        ! LU decomposition
        g%lu1 => g%memory(:, ig:)

        g%lu1(:, 1:g%nb_diag_1(1)) = g%lhs1(:, 1:g%nb_diag_1(1))
        if (g%periodic) then
            select case (g%nb_diag_1(1))
            case (3)
                call TRIDPFS(nx, g%lu1(1, 1), g%lu1(1, 2), g%lu1(1, 3), g%lu1(1, 4), g%lu1(1, 5))
            case (5)
                call PENTADPFS(nx, g%lu1(1, 1), g%lu1(1, 2), g%lu1(1, 3), g%lu1(1, 4), g%lu1(1, 5), g%lu1(1, 6), g%lu1(1, 7))
            end select

            ig = ig + g%nb_diag_1(1) + 2

        else                            ! biased,  different BCs
            bcs_cases(1:4) = [BCS_DD, BCS_ND, BCS_DN, BCS_NN]
            do ib = 1, 4
                ip = (ib - 1)*5

                g%lu1(:, ip + 1:ip + g%nb_diag_1(1)) = g%lhs1(:, 1:g%nb_diag_1(1))

                call FDM_Bcs_Neumann(bcs_cases(ib), g%lu1(:, ip + 1:ip + g%nb_diag_1(1)), g%rhs1(:, 1:g%nb_diag_1(2)), g%rhs1_b, g%rhs1_t)

                nmin = 1; nmax = nx
                if (any([BCS_ND, BCS_NN] == bcs_cases(ib))) nmin = nmin + 1
                if (any([BCS_DN, BCS_NN] == bcs_cases(ib))) nmax = nmax - 1
                nsize = nmax - nmin + 1

                select case (g%nb_diag_1(1))
                case (3)
                    call TRIDFS(nsize, g%lu1(nmin:, ip + 1), g%lu1(nmin:, ip + 2), g%lu1(nmin:, ip + 3))
                case (5)
                    call PENTADFS2(nsize, g%lu1(nmin:, ip + 1), g%lu1(nmin:, ip + 2), g%lu1(nmin:, ip + 3), g%lu1(nmin:, ip + 4), g%lu1(nmin:, ip + 5))
                end select

                ig = ig + 5

            end do

        end if

        ! ###################################################################
        ! second-order derivative
        ! ###################################################################
        g%lhs2 => g%memory(:, ig:)
        ig = ig + 5
        g%rhs2 => g%memory(:, ig:)
        ig = ig + 7 + 5

        ! -------------------------------------------------------------------
        ! uniform grid to calculate Jacobian (needed to set up the Jacobian formulations).
        g%nodes(:) = [(real(i - 1, wp), i=1, g%size)]
        g%jac(:, 2) = 1.0_wp
        g%jac(:, 3) = 0.0_wp

        call FDM_Der2_CreateSystem(g, periodic=.false.)

        ! LU decomposition
        select case (g%nb_diag_2(1))
        case (3)
            call TRIDFS(nx, g%lhs2(:, 1), g%lhs2(:, 2), g%lhs2(:, 3))
        case (5)
            call PENTADFS2(nx, g%lhs2(:, 1), g%lhs2(:, 2), g%lhs2(:, 3), g%lhs2(:, 4), g%lhs2(:, 5))
        end select

        ! Calculating derivative d2xds2 into g%jac(:, 3)
        periodic_aux = g%periodic
        g%periodic = .false.
        call FDM_Der2_Solve(1, g, g%lhs2, nodes, g%jac(:, 3), g%jac(:, 2), g%jac(:, 2)) !g%jac(:, 2) is used as aux array...
        g%periodic = periodic_aux

        ! -------------------------------------------------------------------
        ! Actual grid; possibly nonuniform
        g%nodes(:) = nodes(1:nx)
        g%jac(:, 2) = g%jac(:, 1)

        if (g%periodic) then                                        ! modified wavenumbers
            g%mwn2 => g%memory(:, ig)
            ig = ig + 1
        end if

        call FDM_Der2_CreateSystem(g, g%periodic)

        if (g%periodic) g%mwn2(:) = g%mwn2(:)/(g%jac(1, 1)**2)      ! normalized by dx

        ! -------------------------------------------------------------------
        ! LU decomposition
        g%lu2 => g%memory(:, ig:)

        g%lu2(:, 1:g%nb_diag_2(1)) = g%lhs2(:, 1:g%nb_diag_2(1))
        if (g%periodic) then
            select case (g%nb_diag_2(1))
            case (3)
                call TRIDPFS(nx, g%lu2(1, 1), g%lu2(1, 2), g%lu2(1, 3), g%lu2(1, 4), g%lu2(1, 5))
            end select
            ig = ig + g%nb_diag_2(1) + 2

        else
            select case (g%nb_diag_2(1))
            case (3)
                call TRIDFS(nx, g%lu2(:, 1), g%lu2(:, 2), g%lu2(:, 3))
            end select
            ig = ig + g%nb_diag_2(1)

        end if

        ! ###################################################################
        ! interpolation for staggered cases
        ! ###################################################################
        if (stagger_on) then
            if (g%periodic) then

                ! interpolation
                g%lu0i => g%memory(:, ig:)
                ig = ig + 5

                select case (g%mode_fdm1)
                case DEFAULT
                    call FDM_C0INT6P_LHS(nx, g%lu0i(:, 1), g%lu0i(:, 2), g%lu0i(:, 3))
                end select

                ! LU decomposition
                call TRIDPFS(nx, g%lu0i(1, 1), g%lu0i(1, 2), g%lu0i(1, 3), g%lu0i(1, 4), g%lu0i(1, 5))

                ! first interp. derivative
                g%lu1i => g%memory(:, ig:)
                ig = ig + 5

                select case (g%mode_fdm1)
                case DEFAULT
                    call FDM_C1INT6P_LHS(nx, g%jac, g%lu1i(:, 1), g%lu1i(:, 2), g%lu1i(:, 3))
                end select

                ! LU decomposition
                call TRIDPFS(nx, g%lu1i(1, 1), g%lu1i(1, 2), g%lu1i(1, 3), g%lu1i(1, 4), g%lu1i(1, 5))

                ! else
                !     call TLab_Write_ASCII(efile, 'Staggered grid only along periodic directions.')
                !     call TLab_Stop(DNS_ERROR_UNDEVELOP)

            end if

        end if

! ###################################################################
! Check array sizes
! ###################################################################
        if (ig >= inb_grid) then
            call TLab_Write_ASCII(efile, __FILE__//'. Grid size incorrect.')
            call TLab_Stop(DNS_ERROR_DIMGRID)
        end if

! ###################################################################
! first-order integrals (cases lambda = 0.0_wp)
! ###################################################################
        if (present(fdmi)) then
            if (g%periodic) then
                call TLab_Write_ASCII(wfile, __FILE__//'. Integral algorithms not available for periodic cases.')
            else
                ndl = g%nb_diag_1(1)
                ndr = g%nb_diag_1(2)

                bcs_cases(1:2) = [BCS_MIN, BCS_MAX]
                do ib = 1, 2
                    fdmi(ib)%mode_fdm1 = g%mode_fdm1
                    fdmi(ib)%bc = bcs_cases(ib)
                    call FDM_Int1_Initialize(g%nodes(:), g%lhs1(:, 1:ndl), g%rhs1(:, 1:ndr), 0.0_wp, fdmi(ib))

                end do
            end if
        end if

        return
    end subroutine FDM_Initialize

    ! ###################################################################
    ! ###################################################################
    subroutine FDM_Der1_CreateSystem(g, periodic)
        type(fdm_dt), intent(inout) :: g
        logical, intent(in) :: periodic

        ! -------------------------------------------------------------------
        real(wp) :: coef(5)
        integer(wi) i, nx

        ! ###################################################################
        select case (g%mode_fdm1)
        case (FDM_COM4_JACOBIAN)
            call FDM_C1N4_Jacobian(g%size, g%jac, g%lhs1, g%rhs1, g%nb_diag_1, coef, periodic)

        case (FDM_COM6_JACOBIAN, FDM_COM6_JACOBIAN_HYPER)
            call FDM_C1N6_Jacobian(g%size, g%jac, g%lhs1, g%rhs1, g%nb_diag_1, coef, periodic)

        case (FDM_COM6_JACOBIAN_PENTA)
            call FDM_C1N6_Jacobian_Penta(g%size, g%jac, g%lhs1, g%rhs1, g%nb_diag_1, coef, periodic)

        case (FDM_COM4_DIRECT)
            call FDM_C1N4_Direct(g%size, g%nodes, g%lhs1, g%rhs1, g%nb_diag_1)

        case (FDM_COM6_DIRECT)
            call FDM_C1N6_Direct(g%size, g%nodes, g%lhs1, g%rhs1, g%nb_diag_1)

        end select

        ! -------------------------------------------------------------------
        ! modified wavenumbers
        if (periodic) then
            nx = g%size

#define wn(i) g%mwn1(i)

            do i = 1, nx        ! wavenumbers, the independent variable to construct the modified ones
                if (i <= nx/2 + 1) then
                    wn(i) = 2.0_wp*pi_wp*real(i - 1, wp)/real(nx, wp)
                else
                    wn(i) = 2.0_wp*pi_wp*real(i - 1 - nx, wp)/real(nx, wp)
                end if
            end do

            if (.not. stagger_on) then

                g%mwn1(:) = 2.0_wp*(coef(3)*sin(wn(:)) + coef(4)*sin(2.0_wp*wn(:)) + coef(5)*sin(3.0_wp*wn(:))) &
                            /(1.0_wp + 2.0_wp*coef(1)*cos(wn(:)) + 2.0_wp*coef(2)*cos(wn(:)))

            else ! staggered case has different modified wavenumbers!

                select case (g%mode_fdm1)

                case DEFAULT
                    coef = [9.0_wp/62.0_wp, 0.0_wp, 63.0_wp/62.0_wp, 17.0_wp/62.0_wp, 0.0_wp]

                end select

                g%mwn1(:) = 2.0_wp*(coef(3)*sin(1.0_wp/2.0_wp*wn(:)) + coef(4)/3.0_wp*sin(3.0_wp/2.0_wp*wn(:))) &
                            /(1.0_wp + 2.0_wp*coef(1)*cos(wn(:)))

            end if

#undef wn

        end if

        return
    end subroutine FDM_Der1_CreateSystem

! ###################################################################
! ###################################################################
    subroutine FDM_Der1_Solve(nlines, bcs, g, lu1, u, result, wrk2d)
        integer(wi), intent(in) :: nlines   ! # of lines to be solved
        integer(wi), intent(in) :: bcs(2)   ! BCs at xmin (1) and xmax (2):
        !                                   0 biased, non-zero
        !                                   1 forced to zero
        type(fdm_dt), intent(in) :: g
        real(wp), intent(in) :: lu1(:, :)
        real(wp), intent(in) :: u(nlines, g%size)
        real(wp), intent(out) :: result(nlines, g%size)
        real(wp), intent(inout) :: wrk2d(*)

        integer(wi) nmin, nmax, nsize, ip, ibc

! ###################################################################
        ibc = bcs(1) + bcs(2)*2
        ip = ibc*5

        nmin = 1; nmax = g%size
        if (any([BCS_ND, BCS_NN] == ibc)) then
            result(:, 1) = 0.0_wp      ! homogeneous bcs
            nmin = nmin + 1
        end if
        if (any([BCS_DN, BCS_NN] == ibc)) then
            result(:, g%size) = 0.0_wp
            nmax = nmax - 1
        end if
        nsize = nmax - nmin + 1

        if (any([FDM_COM4_DIRECT, FDM_COM6_DIRECT] == g%mode_fdm1)) then
            select case (g%nb_diag_1(2))
            case (3)
                call MatMul_3d(g%size, nlines, g%rhs1(:, 1), g%rhs1(:, 2), g%rhs1(:, 3), &
                               u, result)
            case (5)
                call MatMul_5d(g%size, nlines, g%rhs1(:, 1), g%rhs1(:, 2), g%rhs1(:, 3), g%rhs1(:, 4), g%rhs1(:, 5), &
                               u, result)
            end select
        else
            select case (g%nb_diag_1(2))
            case (3)
                call MatMul_3d_antisym(g%size, nlines, g%rhs1(:, 1), g%rhs1(:, 2), g%rhs1(:, 3), &
                                       u, result, g%periodic, ibc, g%rhs1_b, g%rhs1_t)
            case (5)
                call MatMul_5d_antisym(g%size, nlines, g%rhs1(:, 1), g%rhs1(:, 2), g%rhs1(:, 3), g%rhs1(:, 4), g%rhs1(:, 5), &
                                       u, result, g%periodic, ibc, g%rhs1_b, g%rhs1_t)
            case (7)
                call MatMul_7d_antisym(g%size, nlines, g%rhs1(:, 1), g%rhs1(:, 2), g%rhs1(:, 3), g%rhs1(:, 4), g%rhs1(:, 5), g%rhs1(:, 6), g%rhs1(:, 7), &
                                       u, result, g%periodic, ibc, g%rhs1_b, g%rhs1_t)
            end select
        end if

        if (g%periodic) then
            select case (g%nb_diag_1(1))
            case (3)
                call TRIDPSS(g%size, nlines, lu1(1, 1), lu1(1, 2), lu1(1, 3), lu1(1, 4), lu1(1, 5), &
                             result, wrk2d)
            case (5)
                call PENTADPSS(g%size, nlines, lu1(1, 1), lu1(1, 2), lu1(1, 3), lu1(1, 4), lu1(1, 5), lu1(1, 6), lu1(1, 7), &
                               result)
            end select

        else
            select case (g%nb_diag_1(1))
            case (3)
                call TRIDSS(nsize, nlines, lu1(nmin:, ip + 1), lu1(nmin:, ip + 2), lu1(nmin:, ip + 3), &
                            result(:, nmin:))
            case (5)
                call PENTADSS2(nsize, nlines, lu1(nmin:, ip + 1), lu1(nmin:, ip + 2), lu1(nmin:, ip + 3), lu1(nmin:, ip + 4), lu1(nmin:, ip + 5), &
                               result(:, nmin:))
            end select

        end if

        return
    end subroutine FDM_Der1_Solve

    ! ###################################################################
    ! ###################################################################
    subroutine FDM_Der2_CreateSystem(g, periodic)
        type(fdm_dt), intent(inout) :: g
        logical, intent(in) :: periodic

        ! -------------------------------------------------------------------
        real(wp) :: coef(5)
        integer(wi) i, nx

        ! ###################################################################
        select case (g%mode_fdm2)
        case (FDM_COM4_JACOBIAN)
            call FDM_C2N4_Jacobian(g%size, g%jac(:, 2), g%lhs2, g%rhs2, g%nb_diag_2, coef, periodic)
            if (.not. g%uniform) g%need_1der = .true.

        case (FDM_COM6_JACOBIAN, FDM_COM6_JACOBIAN_PENTA)
            call FDM_C2N6_Jacobian(g%size, g%jac(:, 2), g%lhs2, g%rhs2, g%nb_diag_2, coef, periodic)
            if (.not. g%uniform) g%need_1der = .true.

        case (FDM_COM6_JACOBIAN_HYPER)
            call FDM_C2N6_Hyper_Jacobian(g%size, g%jac(:, 2), g%lhs2, g%rhs2, g%nb_diag_2, coef, periodic)
            if (.not. g%uniform) g%need_1der = .true.

        case (FDM_COM4_DIRECT)
            call FDM_C2N4_Direct(g%size, g%nodes, g%lhs2, g%rhs2, g%nb_diag_2)

        case (FDM_COM6_DIRECT)
            call FDM_C2N6_Direct(g%size, g%nodes, g%lhs2, g%rhs2, g%nb_diag_2)

        end select

        ! -------------------------------------------------------------------
        ! modified wavenumbers
        if (periodic) then
            nx = g%size

#define wn(i) g%mwn2(i)

            do i = 1, nx        ! wavenumbers, the independent variable to construct the modified ones
                if (i <= nx/2 + 1) then
                    wn(i) = 2.0_wp*pi_wp*real(i - 1, wp)/real(nx, wp)
                else
                    wn(i) = 2.0_wp*pi_wp*real(i - 1 - nx, wp)/real(nx, wp)
                end if
            end do

            g%mwn2(:) = 2.0_wp*(coef(3)*(1.0_wp - cos(wn(:))) + coef(4)*(1.0_wp - cos(2.0_wp*wn(:))) + coef(5)*(1.0_wp - cos(3.0_wp*wn(:)))) &
                        /(1.0_wp + 2.0_wp*coef(1)*cos(wn(:)) + 2.0_wp*coef(2)*cos(2.0_wp*wn(:)))

#undef wn

        end if

        return
    end subroutine FDM_Der2_CreateSystem

    ! ###################################################################################
    ! ###################################################################################
    subroutine FDM_Der2_Solve(nlines, g, lu2, u, result, du, wrk2d)
        integer(wi), intent(in) :: nlines                  ! # of lines to be solved
        type(fdm_dt), intent(in) :: g
        real(wp), intent(in) :: lu2(:, :)
        real(wp), intent(in) :: u(nlines, g%size)
        real(wp), intent(in) :: du(nlines, g%size)          ! 1. derivative for correction in case of Jacobian formulation
        real(wp), intent(out) :: result(nlines, g%size)
        real(wp), intent(out) :: wrk2d(*)

        integer(wi) ip

        ! ###################################################################
        if (any([FDM_COM4_DIRECT, FDM_COM6_DIRECT] == g%mode_fdm2)) then
            select case (g%nb_diag_2(2))
            case (5)
                call MatMul_5d(g%size, nlines, g%rhs2(:, 1), g%rhs2(:, 2), g%rhs2(:, 3), g%rhs2(:, 4), g%rhs2(:, 5), &
                               u, result)
            end select
        else
            select case (g%nb_diag_2(2))
            case (5)
                call MatMul_5d_sym(g%size, nlines, g%rhs2(:, 1), g%rhs2(:, 2), g%rhs2(:, 3), g%rhs2(:, 4), g%rhs2(:, 5), &
                                   u, result, g%periodic)
            case (7)
                call MatMul_7d_sym(g%size, nlines, g%rhs2(:, 1), g%rhs2(:, 2), g%rhs2(:, 3), g%rhs2(:, 4), g%rhs2(:, 5), g%rhs2(:, 6), g%rhs2(:, 7), &
                                   u, result, g%periodic)
            end select
            if (g%need_1der) then
                ip = g%nb_diag_2(2)      ! add Jacobian correction A_2 dx2 du
                ! so far, only tridiagonal systems
                call MatMul_3d_add(g%size, nlines, g%rhs2(:, ip + 1), g%rhs2(:, ip + 2), g%rhs2(:, ip + 3), du, result)
            end if
        end if

        if (g%periodic) then
            select case (g%nb_diag_2(1))
            case (3)
                call TRIDPSS(g%size, nlines, lu2(1, 1), lu2(1, 2), lu2(1, 3), lu2(1, 4), lu2(1, 5), &
                             result, wrk2d)
            end select
        else
            select case (g%nb_diag_2(1))
            case (3)
                call TRIDSS(g%size, nlines, lu2(:, 1), lu2(:, 2), lu2(:, 3), &
                            result)
            end select
        end if

        return
    end subroutine FDM_Der2_Solve

    ! ###################################################################
    ! ###################################################################
    subroutine FDM_Interpol(dir, nlines, g, u, result, wrk2d)
        integer(wi), intent(in) :: dir      ! scalar direction flag
        !                                   0 'vp' --> vel. to pre. grid
        !                                   1 'pv' --> pre. to vel. grid
        integer(wi), intent(in) :: nlines   ! number of lines to be solved
        type(fdm_dt), intent(in) :: g
        real(wp), intent(in) :: u(nlines, g%size)
        real(wp), intent(out) :: result(nlines, g%size)
        real(wp), intent(inout) :: wrk2d(*)

        ! ###################################################################
        ! Interpolation, direction 'vp': vel. --> pre. grid
        if (dir == 0) then
            if (g%periodic) then
                select case (g%mode_fdm1)
                case DEFAULT
                    call FDM_C0INTVP6P_RHS(g%size, nlines, u, result)
                end select
                call TRIDPSS(g%size, nlines, g%lu0i(1, 1), g%lu0i(1, 2), g%lu0i(1, 3), g%lu0i(1, 4), g%lu0i(1, 5), result, wrk2d)
            else
                call TLab_Write_ASCII(efile, 'FDM_Interpol. Non-periodic case not implemented.')
                call TLab_Stop(DNS_ERROR_NOTIMPL)
            end if
            ! Interpolation, direction 'pv': pre. --> vel. grid
        else if (dir == 1) then
            if (g%periodic) then
                select case (g%mode_fdm1)
                case DEFAULT
                    call FDM_C0INTPV6P_RHS(g%size, nlines, u, result)
                end select
                call TRIDPSS(g%size, nlines, g%lu0i(1, 1), g%lu0i(1, 2), g%lu0i(1, 3), g%lu0i(1, 4), g%lu0i(1, 5), result, wrk2d)
            else
                call TLab_Write_ASCII(efile, 'FDM_Interpol. Non-periodic case not implemented.')
                call TLab_Stop(DNS_ERROR_NOTIMPL)
            end if
        end if

        return
    end subroutine FDM_Interpol

    ! ###################################################################
    ! ###################################################################
    subroutine FDM_Interpol_Der1(dir, nlines, g, u, result, wrk2d)
        integer(wi), intent(in) :: dir      ! scalar direction flag
        !                                   0 'vp' --> vel. to pre. grid
        !                                   1 'pv' --> pre. to vel. grid
        integer(wi), intent(in) :: nlines   ! number of lines to be solved
        type(fdm_dt), intent(in) :: g
        real(wp), intent(in) :: u(nlines, g%size)
        real(wp), intent(out) :: result(nlines, g%size)
        real(wp), intent(inout) :: wrk2d(*)

        ! ###################################################################
        ! 1st interpolatory derivative, direction 'vp': vel. --> pre. grid
        if (dir == 0) then
            if (g%periodic) then
                select case (g%mode_fdm1)
                case default
                    call FDM_C1INTVP6P_RHS(g%size, nlines, u, result)
                end select
                call TRIDPSS(g%size, nlines, g%lu1i(1, 1), g%lu1i(1, 2), g%lu1i(1, 3), g%lu1i(1, 4), g%lu1i(1, 5), result, wrk2d)
            else
                call TLab_Write_ASCII(efile, 'FDM_Interpol_Der1. Non-periodic case not implemented.')
                call TLab_Stop(DNS_ERROR_NOTIMPL)
            end if
            ! 1st interpolatory derivative, direction 'pv': pre. --> vel. grid
        else if (dir == 1) then
            if (g%periodic) then
                select case (g%mode_fdm1)
                case default
                    call FDM_C1INTPV6P_RHS(g%size, nlines, u, result)
                end select
                call TRIDPSS(g%size, nlines, g%lu1i(1, 1), g%lu1i(1, 2), g%lu1i(1, 3), g%lu1i(1, 4), g%lu1i(1, 5), result, wrk2d)
            else
                call TLab_Write_ASCII(efile, 'FDM_Interpol_Der1. Non-periodic case not implemented.')
                call TLab_Stop(DNS_ERROR_NOTIMPL)
            end if
        end if

        return
    end subroutine FDM_Interpol_Der1

end module FDM
