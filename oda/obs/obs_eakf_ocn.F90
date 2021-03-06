module obs_eakf_ocn_mod

  ! FMS Shared modules
  use fms_mod, only : file_exist, open_file, open_namelist_file, check_nml_error, write_version_number, close_file
  use fms_mod, only : error_mesg, FATAL, WARNING
  use mpp_mod, only : mpp_pe, mpp_root_pe, stdlog, stdout
  use constants_mod, only : DEG_TO_RAD
  use oda_types_mod, only : ocean_profile_type, grid_type

  ! EAKF SUP modules
  use obs_tools_mod, only : conv_state_to_obs, obs_def_type, def_single_obs, def_single_obs_end
  use loc_and_dist_mod, only : loc_type


  private
  public take_single_obs, obs_init, obs_end, obs_def, get_close_grids

  integer :: num_obs = 0
  integer :: num_prfs = 0

  ! Following is to allow initialization of obs_def_type
  logical :: first_run_call = .true.

  type (obs_def_type), allocatable, dimension(:) :: obs_def

  !---- namelist with default values
  ! Set a cut-off for lon and lat for close obs search
  real :: close_lat_window = 10.0
  real :: close_lon_window = 10.0

  namelist /obs_nml/ close_lat_window, close_lon_window

  !--- module name and version number
  character(len=*), parameter :: MODULE_NAME = 'obs_eakf_ocn_mod'
  character(len=*), parameter :: VERS_NUM = '$Id$'

contains

  ! Initializes the description a linear observations operator. For each
  ! observation, a list of the state variables on which it depends and the
  ! coefficients for each state variable is passed to def_single_obs
  ! which establishes appropriate data structures.
  subroutine obs_init(isd_ens, ied_ens, jsd_ens, jed_ens, halox, haloy, Profiles, nprof, max_levels,&
       & T_grid, list_loc_halo_prfs, num_prfs_loc_halo)
    integer, intent(in) :: isd_ens, ied_ens, jsd_ens, jed_ens, halox, haloy
    type(ocean_profile_type), intent(in), dimension(:) :: Profiles
    integer, intent(in) :: nprof, max_levels
    type(grid_type), intent(in) :: T_grid
    integer, intent(inout), dimension(:) :: list_loc_halo_prfs
    integer, intent(inout) :: num_prfs_loc_halo

    real :: frac_lon, frac_lat, frac_k
    real, dimension(6) :: coef

    integer :: i, k, k0, ii, jj, kk0, blk, i_o, lon_len, ie
    integer :: idx_obs, ni, nj, nk
    integer :: unit, istat, stdlog_unit, stdout_unit
    integer, dimension(8) :: state_index

    character(len=256) :: emsg_local

    stdout_unit = stdout()
    stdlog_unit = stdlog()

    ni = T_grid%ni
    nj = T_grid%nj
    nk = T_grid%nk

    num_prfs = nprof
    lon_len = ied_ens-isd_ens+2*halox+1
    blk = (jed_ens-jsd_ens+2*haloy+1)*lon_len

    ! Read namelist for run time control
    if ( file_exist('input.nml') ) then
       unit = open_namelist_file()
       read (UNIT=unit, NML=obs_nml, IOSTAT=istat)
       call close_file(unit)
    else
       ! Set istat to an arbitrary positive number if input.nml does not exist
       istat = 100
    end if

    if ( check_nml_error(istat, 'obs_nml') < 0 ) then
       call error_mesg(MODULE_NAME//'::obs_init', 'OBS_NML not found in input.nml, using defaults.', WARNING)
    end if

    ! Write the namelist to a log file
    call write_version_number(VERS_NUM, MODULE_NAME)

    ! Initialization for identity observations
    if (  mpp_pe() == mpp_root_pe() .and. first_run_call ) then
       write (UNIT=stdout_unit, NML=obs_nml)
       write (UNIT=stdlog_unit, NML=obs_nml)
    end if

    num_prfs_loc_halo = 0
    list_loc_halo_prfs(:) = 0

    do i=1, nprof
       ii = Profiles(i)%i_index
       jj = Profiles(i)%j_index

       if ( jsd_ens > 1 .and. jed_ens < nj ) then ! for m-middle domains
          if ( jj >= jsd_ens-haloy .and. jj <= jed_ens+haloy ) then
             if ( isd_ens > 1 .and. ied_ens < ni ) then ! for z-middle domains
                if ( ii >= isd_ens-halox .and. ii <= ied_ens+halox ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( ied_ens == ni ) then ! for z-rightmost domains
                if ( (ii >= isd_ens-halox .and. ii <= ni) .or.&
                     & (ii >= 1 .and. ii <= halox) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( isd_ens == 1 ) then ! for z-leftmost domains
                if ( (ii >= 1 .and. ii <= ied_ens+halox) .or.&
                     & (ii >= ni-halox+1 .and. ii <= ni) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             end if
          end if
       else if ( jed_ens == nj ) then ! for m-northmost domains
          if ( jj >= jsd_ens-haloy .and. jj <= nj ) then
             if ( ied_ens < ni .and. isd_ens > 1 ) then ! for z-middle domains
                if ( ii >= isd_ens-halox .and. ii <= ied_ens+halox ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( ied_ens == ni ) then ! for z-rightmost domains
                if ( (ii >= isd_ens-halox .and. ii <= ni) .or.&
                     & (ii >= 1 .and. ii<= halox) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( isd_ens == 1 ) then ! for z-leftmost domains
                if ( (ii >= ni-halox+1 .and. ii <= ni) .or.&
                     & (ii >= 1 .and. ii <= ied_ens+halox) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             end if
          end if
       else if ( jsd_ens == 1 ) then ! for m-southmost domains
          if ( jj >= 1 .and. jj <= jed_ens+haloy ) then
             if ( isd_ens > 1 .and. ied_ens < ni ) then ! for z-middle domains
                if ( ii >= isd_ens-halox .and. ii <= ied_ens+halox ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( ied_ens == ni ) then ! for z-rightmost domains
                if ( (ii >= isd_ens-halox .and. ii <= ni ) .or.&
                     & (ii >= 1 .and. ii <= halox) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             else if ( isd_ens == 1 ) then ! for z-leftmost domains
                if ( (ii >= 1 .and. ii <= ied_ens+halox) .or.&
                     & (ii >= ni-halox+1 .and. ii <= ni) ) then
                   num_prfs_loc_halo = num_prfs_loc_halo + 1
                   list_loc_halo_prfs(num_prfs_loc_halo) = i
                end if
             end if
          end if
       end if
    end do

!!$    write (UNIT=stdout_unit, FMT='("PE ",I6,": num_prfs_loc = ",I8,", num_prfs_loc_halo = ",I8)') mpp_pe(), num_prfs_loc, num_prfs_loc_halo

    num_obs = 0
    do i=1, num_prfs_loc_halo
       i_o = list_loc_halo_prfs(i)
       kk0 = Profiles(i_o)%levels
       if ( kk0 > max_levels ) kk0 = max_levels
       num_obs = num_obs+kk0
    end do

    allocate(obs_def(num_obs))

!!$    write (UNIT=stdout_unit, FMT=*) "Running here 0"

    idx_obs = 0
    do i=1, num_prfs_loc_halo
       i_o = list_loc_halo_prfs(i)
       ii = Profiles(i_o)%i_index
       jj = Profiles(i_o)%j_index

       if ( 1 < isd_ens .and. ied_ens < ni ) then ! 4 i-interior sub-domain
          if ( ii < (isd_ens-halox) .or. ii > (ied_ens+halox) .or.&
               & jj < (jsd_ens-haloy) .or. jj > (jed_ens+haloy) ) then
             if ( ii < (isd_ens-halox) ) then
                write (UNIT=emsg_local, FMT='("ii = ",I5," which is less than isd_ens-halox = ",I8)') ii, isd_ens-halox
                call error_mesg(MODULE_NAME//'::obs_init', trim(emsg_local), FATAL)
             end if
             if ( ii > (ied_ens+halox) ) then
                write (UNIT=emsg_local, FMT='("ii = ",I5," which is less than ied_ens+halox = ",I8)') ii, ied_ens+halox
                call error_mesg(MODULE_NAME//'::obs_init', trim(emsg_local), FATAL)
             end if
          end if
       end if
       if ( jj < 1 .or. jj > nj ) then
          write (UNIT=emsg_local, FMT='("jj = ",I5," is outside the range [1,",I5,"]")') jj, nj
          call error_mesg(MODULE_NAME//'::obs_init', trim(emsg_local), FATAL)
       end if

       frac_lat = Profiles(i_o)%j_index - jj
       frac_lon = Profiles(i_o)%i_index - ii

       coef(1) = (1.0 - frac_lon) * (1.0 - frac_lat)
       coef(2) = frac_lon * (1.0 - frac_lat)
       coef(3) = (1.0 - frac_lon) * frac_lat
       coef(4) = frac_lon * frac_lat

       kk0 = Profiles(i_o)%levels
       if ( kk0 > max_levels ) kk0 = max_levels

       do k=1, kk0
          idx_obs = idx_obs + 1
          k0 = Profiles(i_o)%k_index(k)
          frac_k = Profiles(i_o)%k_index(k) - k0

          if ( ied_ens == ni .and. ii <= halox ) then
             ii = ii + ni
          end if
          if ( isd_ens == 1 .and. ii > ied_ens+halox ) then
             ii = ii - ni
          end if

          if ( k0 == 0 ) then
             state_index(1) = (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 1
             state_index(2) = (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 2
             state_index(3) = (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 1
             state_index(4) = (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 2
             state_index(5) = state_index(1)
             state_index(6) = state_index(2)
             state_index(7) = state_index(3)
             state_index(8) = state_index(4)
          else if (k0 == nk ) then
             state_index(1) = (k0-1)*blk + (jj-jsd_ens+haloy)*lon_len+ii-isd_ens+halox+1
             state_index(2) = (k0-1)*blk + (jj-jsd_ens+haloy)*lon_len+ii-isd_ens+halox+2
             state_index(3) = (k0-1)*blk + (jj-jsd_ens+haloy+1)*lon_len+ii-isd_ens+halox+1
             state_index(4) = (k0-1)*blk + (jj-jsd_ens+haloy+1)*lon_len+ii-isd_ens+halox+2
             state_index(5) = state_index(1)
             state_index(6) = state_index(2)
             state_index(7) = state_index(3)
             state_index(8) = state_index(4)
          else
             state_index(1) = (k0-1)*blk + (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 1
             state_index(2) = (k0-1)*blk + (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 2
             state_index(3) = (k0-1)*blk + (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 1
             state_index(4) = (k0-1)*blk + (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 2
             state_index(5) = k0*blk + (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 1
             state_index(6) = k0*blk + (jj-jsd_ens+haloy)*lon_len + ii-isd_ens+halox + 2
             state_index(7) = k0*blk + (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 1
             state_index(8) = k0*blk + (jj-jsd_ens+haloy+1)*lon_len + ii-isd_ens+halox + 2
          end if


          do ie=1, 8
             if ( state_index(ie) < 0 ) then
                write (UNIT=emsg_local, FMT='("state_index(",I1,") = ",I8," < 0 at [ii,jj] = [",I5,",",I5,"]&
                     & within [isd_ens,ied_ens] = [",I5,",",I5,"] and [jsd_ens,jed_ens] = [",I5,",",I5,&
                     & "], with halox = ",I5,", haloy = ",I5,", k0 = ",I5,", blk = ",I5,", nk = ",I5)')&
                     & ie, state_index(ie), ii, jj, isd_ens, ied_ens, jsd_ens, jed_ens, halox, haloy, k0, blk, nk
                call error_mesg(MODULE_NAME//'::obs_init', trim(emsg_local), FATAL)
             end if
          end do

          if ( frac_lon == 0.0 ) then
             state_index(2) = state_index(1)
             state_index(4) = state_index(3)
             state_index(6) = state_index(5)
             state_index(8) = state_index(7)
          end if

          if ( frac_lat == 0.0 ) then
             state_index(3) = state_index(1)
             state_index(4) = state_index(2)
             state_index(7) = state_index(5)
             state_index(8) = state_index(6)
          end if

          coef(5) = 1.0 - frac_k
          coef(6) = frac_k

          if ( frac_k == 0.0 ) then
             state_index(5) = state_index(1)
             state_index(6) = state_index(2)
             state_index(7) = state_index(3)
             state_index(8) = state_index(4)
          end if

          call def_single_obs(8, state_index(1:8), coef(1:6), obs_def(idx_obs))
       end do
    end do

!!$    write (UNIT=stdout_unit, FMT='("PE ",I5," running here 1")') mpp_pe()

    first_run_call = .false.
  end subroutine obs_init

  subroutine obs_end()

    integer :: i

    do i=1, num_obs
       call def_single_obs_end(obs_def(i))
    end do

    deallocate(obs_def)
  end subroutine obs_end

  function take_single_obs(x, index)
    real, intent(in), dimension(:) :: x
    integer, intent(in) :: index

    real :: take_single_obs
    real, dimension(1) :: take

    ! Given a model state, x, returns the expection of observations for
    ! assimilation. For perfect model, take_obs is just state_to_obs
    take = conv_state_to_obs(x, obs_def(index:index), 1, index)
    take_single_obs = take(1)
  end function take_single_obs


  ! Computes a list of observations 'close' to each state variable and
  ! returns the list. Num is the number of close obs requested for each state
  ! variable, list is the returned array of close obs points that contain the
  ! obs idx in globa obs list. SNZ -- 08/16/02
  !
  ! in cm2, this subroutine is not used.
  subroutine get_close_obs(model_loc, Profs, list, num)
    type(loc_type), intent(in) :: model_loc
    type(ocean_profile_type), intent(in), dimension(:) :: Profs
    integer, intent(inout), dimension(:) :: list
    integer, intent(inout) :: num

    real :: olon, olat, low_lat, hi_lat, low_lon, hi_lon

    integer :: i, j
!!$    integer :: i0

    ! Get the latitudinal arrange first

    low_lat = model_loc%lat - close_lat_window
    if ( low_lat < -90.0 ) low_lat = -90.0
    hi_lat = model_loc%lat + close_lat_window
    if ( hi_lat > 90.0 ) hi_lat = 90.0

    num = 0
    do j=1, num_prfs
       olon = Profs(j)%lon
       olat = Profs(j)%lat

       if ( low_lat < olat .and. olat < hi_lat ) then
!!$          if ( abs(model_loc%lat) <= 10.0 ) then
!!$             i0 = abs(model_loc%lat)*20 + 0.5 + 1
!!$          else if ( abs(model_loc%lat) <= 20.0 ) then
!!$             i0 = (abs(model_loc%lat)-10.0)*2 + 0.5 + 201
!!$          else
!!$             i0 = abs(model_loc%lat)-20.0 + 0.5 + 221
!!$          end if
!!$          if ( i0 > size(vcos) ) then
!!$             call error_mesg(MODULE_NAME//'::get_close_obs', 'i0 greater than size of vcos', FATAL)
!!$          end if

          low_lon = model_loc%lon - close_lon_window/cos(model_loc%lat*DEG_TO_RAD)
          hi_lon  = model_loc%lon + close_lon_window/cos(model_loc%lat*DEG_TO_RAD)

          if ( low_lon < 0.0 ) then
             low_lon = low_lon + 360.0
             if ( (olon > low_lon) .or. (olon < hi_lon) ) then
                num = num + 1
                list(num) = j
             end if
          else if ( hi_lon > 360.0 ) then
             hi_lon = hi_lon - 360.0
             if ( (olon > low_lon) .or. (olon < hi_lon) ) then
                num = num + 1
                list(num) = j
             end if
          else
             if ( olon > low_lon .and. olon < hi_lon ) then
                num = num + 1
                list(num) = j
             end if
          end if
       end if
    end do
  end subroutine get_close_obs ! not used for cm2

  ! Computes a list of grids 'close' to the index_obs'th' profiles and
  ! returns the list. Num is the number of close grids requested for each state
  ! variable; list is the returned array of close grid points that contain the
  ! grid idx in global grid index from 1-17280. SNZ -- 08/16/02
  subroutine get_close_grids(obs_loc, isd_ens, ied_ens, jsd_ens, jed_ens, halox, haloy, T_grid, list, num)
    type(loc_type), intent(in) :: obs_loc
    integer, intent(in) :: isd_ens, ied_ens, jsd_ens, jed_ens, halox, haloy
    type(grid_type), intent(in) :: T_grid
    integer, intent(inout), dimension(:) :: list
    integer, intent(inout) :: num

    real :: olon, olat, low_lat, hi_lat, low_lon, hi_lon, olat0

    integer :: i, j, i_m, j_m, ni, nj

    character(len=256) :: emsg_local

    type(loc_type) :: model_loc

    ni = T_grid%ni
    nj = T_grid%nj

    olon = obs_loc%lon
    olat = obs_loc%lat
    olat0 = olat
    if ( abs(olat0) > 80.0 ) olat0 = 80.0

    ! Get the latitudinal arrange first
    low_lat = olat - close_lat_window
    if ( low_lat < -90.0 ) low_lat = -87.0
    hi_lat = olat + close_lat_window
    if ( hi_lat > 89.0 ) hi_lat = 89.0

    num = 0
    do j=jsd_ens-haloy, jed_ens+haloy
       do i=isd_ens-halox, ied_ens+halox
          i_m = i
          j_m = j
          if ( i_m <= 0 ) i_m = i_m + ni
          if ( i_m > ni ) i_m = i_m - ni
          if ( j_m <= 0 ) j_m = 1
          if ( j_m > nj ) j_m = nj
          if ( i_m < 1 .or. i_m > ni .or. j_m < 1 .or. j_m > nj ) then
             write (UNIT=emsg_local, FMT='("i_m = ",I8,", j_m = ",I8," outside range i_m = [1,",I8,"] or j_m = [1",I8,"]")')&
                  & i_m, j_m, ni, nj
             call error_mesg(MODULE_NAME//'::get_close_grids', trim(emsg_local), FATAL)
          end if

          model_loc%lon = T_grid%x(i_m,j_m) + 360.0
          model_loc%lat = T_grid%y(i_m,j_m)

          if ( low_lat < model_loc%lat .and. model_loc%lat < hi_lat ) then
             low_lon = olon - close_lon_window/cos(olat0*DEG_TO_RAD)
             if ( low_lon < 0.0 ) low_lon = low_lon + 360.0
             if ( low_lon < 80.5 ) low_lon = low_lon + 360.0
             hi_lon  = olon + close_lon_window/cos(olat0*DEG_TO_RAD)
             if ( hi_lon >= 440.5 ) hi_lon = hi_lon - 360.0

             if (low_lon < hi_lon) then
                if ( (model_loc%lon > low_lon) .and. (model_loc%lon < hi_lon) ) then
                   num = num + 1
                   list(num) = (j-jsd_ens+haloy)*(ied_ens-isd_ens+2*halox+1) + i-isd_ens+halox+1
                end if
             else if ( hi_lon < low_lon ) then
                if ( (model_loc%lon > low_lon .and. model_loc%lon < 440.5) .or.&
                     & (model_loc%lon >= 80.5 .and. model_loc%lon < hi_lon ) ) then
                   num = num + 1
                   list(num) = (j-jsd_ens+haloy)*(ied_ens-isd_ens+2*halox+1) + i-isd_ens+halox+1
                end if
             else
                num = num + 1
                list(num) = (j-jsd_ens+haloy)*(ied_ens-isd_ens+2*halox+1) + i-isd_ens+halox+1
             end if
          end if
       end do
    end do
  end subroutine get_close_grids
end module obs_eakf_ocn_mod
