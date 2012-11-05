
# Copyright (c) 2012 Stefan Eilemann <Stefan.Eilemann@epfl.ch>

include(ExternalProject)
find_package(Git REQUIRED)
include(UseExternalClone)
include(UseExternalMakefile)
include(UseExternalDeps)
include(LSBInfo)

set_property(GLOBAL PROPERTY USE_FOLDERS ON)
file(REMOVE ${CMAKE_BINARY_DIR}/projects.make)

set(USE_EXTERNAL_SUBTARGETS update build buildonly configure test testonly
  install package download deps Makefile stat clean reset)
foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
  add_custom_target(${subtarget}s)
  set_target_properties(${subtarget}s PROPERTIES FOLDER "00_Meta")
endforeach()
add_custom_target(AllProjects)
add_dependencies(updates update)
set_target_properties(AllProjects PROPERTIES FOLDER "00_Main")

add_custom_target(Buildyard-stat
  COMMAND ${GIT_EXECUTABLE} status -s --untracked-files=no
  COMMENT "Buildyard Status:"
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  )
set_target_properties(Buildyard-stat PROPERTIES EXCLUDE_FROM_ALL ON)
add_dependencies(stats Buildyard-stat)

# renames existing origin and adds user URL as new origin (git only)
function(USE_EXTERNAL_CHANGE_ORIGIN name ORIGIN_URL USER_URL ORIGIN_RENAME)
  if(ORIGIN_URL AND USER_URL)
    string(TOUPPER ${name} NAME)
    set(CHANGE_ORIGIN ${GIT_EXECUTABLE} remote set-url origin "${USER_URL}")
    set(RM_REMOTE ${GIT_EXECUTABLE} remote rm ${ORIGIN_RENAME} || ${GIT_EXECUTABLE} status) #workaround to ignore remote rm return value
    set(ADD_REMOTE ${GIT_EXECUTABLE} remote add ${ORIGIN_RENAME} "${ORIGIN_URL}")

    ExternalProject_Add_Step(${name} change_origin
      COMMAND ${CHANGE_ORIGIN}
      COMMAND ${RM_REMOTE}
      COMMAND ${ADD_REMOTE}
      WORKING_DIRECTORY "${${NAME}_SOURCE}"
      DEPENDERS build
      DEPENDEES download
      ALWAYS 1
    )
  endif()
endfunction()


function(USE_EXTERNAL_GATHER_ARGS name)
  # sets ${NAME}_ARGS on return, to be passed to CMake
  string(TOUPPER ${name} NAME)

  set(ARGS)
  set(DEPENDS)
  set(${UPPER_NAME}_ARGS)

  # recurse to get dependency roots
  foreach(proj ${${NAME}_DEPENDS})
    use_external_gather_args(${proj})
    string(TOUPPER ${proj} PROJ)
    set(ARGS ${ARGS} ${${PROJ}_ARGS})
  endforeach()

  get_target_property(_check ${name} _EP_IS_EXTERNAL_PROJECT)
  if(NOT _check EQUAL 1) # installed package
    set(${NAME}_ARGS ${ARGS} PARENT_SCOPE) # return value
    return()
  endif()

  # self root '-DFOO_ROOT=<path>'
  set(INSTALL_PATH "${CMAKE_CURRENT_BINARY_DIR}/install")
  if("${${NAME}_ROOT_VAR}" STREQUAL "")
    set(ARGS ${ARGS} "-D${NAME}_ROOT=${INSTALL_PATH}")
  else()
    set(ARGS ${ARGS} "-D${${NAME}_ROOT_VAR}=${INSTALL_PATH}")
  endif()

  set(${NAME}_ARGS ${ARGS} PARENT_SCOPE) # return value
endfunction()


function(USE_EXTERNAL_BUILDONLY name)
  ExternalProject_Get_Property(${name} binary_dir)

  get_property(cmd_set TARGET ${name} PROPERTY _EP_INSTALL_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_INSTALL_COMMAND)
  else()
    _ep_get_build_command(${name} INSTALL cmd)
  endif()

  add_custom_target(${name}-buildonly
    COMMAND ${cmd}
    COMMENT "Building ${name}"
    WORKING_DIRECTORY ${binary_dir}
    )
  set_target_properties(${name}-buildonly PROPERTIES EXCLUDE_FROM_ALL ON)
endfunction()

function(_ep_add_test_command name)
  ExternalProject_Get_Property(${name} binary_dir)

  get_property(cmd_set TARGET ${name} PROPERTY _EP_TEST_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_TEST_COMMAND)
  else()
    _ep_get_build_command(${name} TEST cmd)
  endif()

  string(REGEX REPLACE "^(.*/)cmake([^/]*)$" "\\1ctest\\2" cmd "${cmd}")
  add_custom_target(${name}-test
    COMMAND ${cmd}
    COMMENT "Testing ${name}"
    WORKING_DIRECTORY ${binary_dir}
    DEPENDS ${name}
    )
  add_custom_target(${name}-testonly
    COMMAND ${cmd}
    COMMENT "Testing ${name}"
    WORKING_DIRECTORY ${binary_dir}
    )
endfunction()


function(USE_EXTERNAL name)
  # Searches for an external project.
  #  Sets NAME_ROOT to the installation directory when not found using
  #  find_package().
  # * First searches using find_package taking into account:
  # ** NAME_ROOT CMake and environment variables
  # ** .../share/name/CMake
  # ** Version is read from optional $name.cmake
  # * If no pre-installed package is found, use ExternalProject to get dependency
  # ** External project settings are read from $name.cmake

  get_property(_check GLOBAL PROPERTY USE_EXTERNAL_${name})
  if(_check) # tested, be quiet and propagate upwards
    set(BUILDING ${BUILDING} PARENT_SCOPE)
    return()
  endif()

  string(SUBSTRING ${name} 0 2 SHORT_NAME)
  string(TOUPPER ${SHORT_NAME} SHORT_NAME)
  string(TOUPPER ${name} NAME)
  set(ROOT ${NAME}_ROOT)
  set(ENVROOT $ENV{${ROOT}})
  set(SHORT_ROOT ${SHORT_NAME}_ROOT)
  set(SHORT_ENVROOT $ENV{${SHORT_ROOT}})

  # CMake module search path
  if(${${SHORT_ROOT}})
    list(APPEND CMAKE_MODULE_PATH "${${SHORT_ROOT}}/share/${name}/CMake")
  endif()
  if(NOT "${SHORT_ENVROOT}" STREQUAL "")
    list(APPEND CMAKE_MODULE_PATH "${SHORT_ENVROOT}/share/${name}/CMake")
  endif()
  if(${${ROOT}})
    list(APPEND CMAKE_MODULE_PATH "${${ROOT}}/share/${name}/CMake")
  endif()
  if(NOT "${ENVROOT}" STREQUAL "")
    list(APPEND CMAKE_MODULE_PATH "${ENVROOT}/share/${name}/CMake")
  endif()

  list(APPEND CMAKE_MODULE_PATH "${CMAKE_INSTALL_PREFIX}/share/${name}/CMake")
  list(APPEND CMAKE_MODULE_PATH /usr/share/${name}/CMake)
  list(APPEND CMAKE_MODULE_PATH /usr/local/share/${name}/CMake)

  # try find_package
  set(USE_EXTERNAL_INDENT "${USE_EXTERNAL_INDENT}  ")
  if(NOT ${NAME}_FORCE_BUILD)
    find_package(${name} ${${NAME}_PACKAGE_VERSION} QUIET)
  endif()
  if(${NAME}_FOUND)
    set(${name}_FOUND 1) # compat with Foo_FOUND and FOO_FOUND usage
  endif()
  if(${name}_FOUND)
    if(NOT "${${NAME}_INCLUDE_DIRS}${${name}_INCLUDE_DIRS}" STREQUAL "")
      message(STATUS "${USE_EXTERNAL_INDENT}${name}: installed in "
        "${${NAME}_INCLUDE_DIRS}${${name}_INCLUDE_DIRS}")
    else()
      message(STATUS "${USE_EXTERNAL_INDENT}${name}: found")
    endif()
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name}_FOUND ON)
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    return()
  endif()

  unset(${name}_INCLUDE_DIR CACHE)  # some find_package (boost) don't properly
  unset(${NAME}_INCLUDE_DIR CACHE)  # unset and recheck the version on subsequent
  unset(${name}_INCLUDE_DIRS CACHE) # runs if it failed
  unset(${NAME}_INCLUDE_DIRS CACHE)
  unset(${name}_LIBRARY_DIRS CACHE)
  unset(${NAME}_LIBRARY_DIRS CACHE)

  if("${${NAME}_REPO_URL}" STREQUAL "")
    message(STATUS
      "${USE_EXTERNAL_INDENT}${name}: No source repo, update ${name}.cmake?")
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    return()
  endif()

  message(STATUS   # print first for nicer output
    "${USE_EXTERNAL_INDENT}${name}: use ${${NAME}_REPO_URL}:${${NAME}_REPO_TAG}"
    )

  # pull in dependent projects first
  add_custom_target(${name}-projects)
  set(DEPENDS)
  set(MISSING)
  set(DEPMODE)
  foreach(_dep ${${NAME}_DEPENDS})
    if(${_dep} STREQUAL "OPTIONAL")
      set(DEPMODE)
    elseif(${_dep} STREQUAL "REQUIRED")
      set(DEPMODE REQUIRED)
    else()
      get_property(_check GLOBAL PROPERTY USE_EXTERNAL_${_dep})
      if(NOT _check)
        use_external(${_dep})
      endif()
      get_property(_found GLOBAL PROPERTY USE_EXTERNAL_${_dep}_FOUND)
      get_target_property(_dep_check ${_dep} _EP_IS_EXTERNAL_PROJECT)

      if(_dep_check EQUAL 1)
        list(APPEND DEPENDS ${_dep})
        if("${DEPMODE}" STREQUAL "REQUIRED")
          add_dependencies(${_dep}-projects ${name} ${name}-projects)
        endif()
      endif()

      if("${DEPMODE}" STREQUAL "REQUIRED" AND NOT _found)
        set(MISSING "${MISSING} ${_dep}")
      endif()
    endif()
  endforeach()
  if(MISSING)
    message(STATUS "${USE_EXTERNAL_INDENT}${name}: SKIP, missing${MISSING}")
    set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
    return()
  endif()

  # External Project
  set(UPDATE_CMD)
  set(REPO_TYPE ${${NAME}_REPO_TYPE})
  if(NOT REPO_TYPE)
    set(REPO_TYPE git)
  endif()
  string(TOUPPER ${REPO_TYPE} REPO_TYPE)
  set(DOWNLOAD_CMD ${REPO_TYPE}_REPOSITORY)
  if(REPO_TYPE STREQUAL "GIT-SVN")
    set(REPO_TYPE GIT)
    set(REPO_TAG GIT_TAG)
    set(GIT_SVN "svn")
    set(DOWNLOAD_CMD ${REPO_TYPE}_REPOSITORY)
    # svn rebase fails with local modifications, ignore
    set(UPDATE_CMD ${GIT_EXECUTABLE} svn rebase || ${GIT_EXECUTABLE} status
      ALWAYS TRUE)
  elseif(REPO_TYPE STREQUAL "GIT")
    set(REPO_TAG GIT_TAG)
    set(REPO_ORIGIN_URL ${${NAME}_REPO_URL})
    set(REPO_USER_URL ${${NAME}_USER_URL})
    set(REPO_ORIGIN_NAME ${${NAME}_ORIGIN_NAME})
    if(REPO_ORIGIN_URL AND REPO_USER_URL)
      if(NOT REPO_ORIGIN_NAME)
        set(REPO_ORIGIN_NAME "root")
      endif()
      set(UPDATE_CMD ${GIT_EXECUTABLE} pull ${REPO_ORIGIN_NAME} ${${NAME}_REPO_TAG} || ${GIT_EXECUTABLE} status
          ALWAYS TRUE)
    else()
      # pull fails if tag is a SHA hash, use git status to set exit value to true
      set(UPDATE_CMD ${GIT_EXECUTABLE} pull || ${GIT_EXECUTABLE} status
          ALWAYS TRUE)
    endif()
  elseif(REPO_TYPE STREQUAL "SVN")
    find_package(Subversion REQUIRED)
    set(REPO_TAG SVN_REVISION)
  elseif(REPO_TYPE STREQUAL "FILE")
    set(DOWNLOAD_CMD URL)
  else()
    message(FATAL_ERROR "Unknown repository type ${REPO_TYPE}")
  endif()

  if(NOT ${NAME}_SOURCE)
    set(${NAME}_SOURCE "${CMAKE_SOURCE_DIR}/src/${name}")
  endif()

  set(INSTALL_PATH "${CMAKE_CURRENT_BINARY_DIR}/install")
  use_external_gather_args(${name})
  set(ARGS -DBUILDYARD:BOOL=ON -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
           -DCMAKE_INSTALL_PREFIX:PATH=${INSTALL_PATH}
           -DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_OSX_ARCHITECTURES}
           ${${NAME}_ARGS} ${${NAME}_CMAKE_ARGS})

  ExternalProject_Add(${name}
    LIST_SEPARATOR !
    PREFIX "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    SOURCE_DIR "${${NAME}_SOURCE}"
    INSTALL_DIR "${INSTALL_PATH}"
    DEPENDS "${DEPENDS}"
    ${DOWNLOAD_CMD} ${${NAME}_REPO_URL}
    ${REPO_TAG} ${${NAME}_REPO_TAG}
    UPDATE_COMMAND ${UPDATE_CMD}
    CMAKE_ARGS ${ARGS}
    TEST_AFTER_INSTALL 1
    ${${NAME}_EXTRA}
    STEP_TARGETS ${USE_EXTERNAL_SUBTARGETS}
    )
  use_external_buildonly(${name})
  file(APPEND ${CMAKE_BINARY_DIR}/projects.make
    "${name}-%:\n"
    "	@\$(MAKE) -C ${CMAKE_BINARY_DIR} $@\n"
    "${name}_%:\n"
    "	@\$(MAKE) -C ${CMAKE_BINARY_DIR}/${name} $*\n\n"
    )

  if(REPO_TYPE STREQUAL "GIT")
    use_external_change_origin(${name} "${REPO_ORIGIN_URL}" "${REPO_USER_URL}"
                              "${REPO_ORIGIN_NAME}")
    unset(${REPO_ORIGIN_URL} CACHE)
    unset(${REPO_USER_URL} CACHE)
    unset(${REPO_ORIGIN_NAME} CACHE)
  endif()

  # add optional targets: package, doxygen, github
  get_property(cmd_set TARGET ${name} PROPERTY _EP_BUILD_COMMAND SET)
  if(cmd_set)
    get_property(cmd TARGET ${name} PROPERTY _EP_BUILD_COMMAND)
  else()
    _ep_get_build_command(${name} BUILD cmd)
  endif()

  use_external_makefile(${name})
  use_external_deps(${name})
  add_custom_target(${name}-clean
    COMMAND ${cmd} clean
    COMMENT "Cleaning ${name}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    )
  set_target_properties(${name}-clean PROPERTIES EXCLUDE_FROM_ALL ON)

  if(NOT APPLE)
    set(fakeroot fakeroot)
    if(LSB_DISTRIBUTOR_ID STREQUAL "Ubuntu" AND
        CMAKE_VERSION VERSION_GREATER 2.8.6)
      set(fakeroot) # done by deb generator
    endif()
  endif()

  add_custom_target(${name}-package
    COMMAND ${fakeroot} ${cmd} package
    COMMENT "Building package"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${name}"
    )
  set_target_properties(${name}-package PROPERTIES EXCLUDE_FROM_ALL ON)

  get_property(cvs_repository TARGET ${name} PROPERTY _EP_CVS_REPOSITORY)
  get_property(svn_repository TARGET ${name} PROPERTY _EP_SVN_REPOSITORY)
  get_property(git_repository TARGET ${name} PROPERTY _EP_GIT_REPOSITORY)

  if(cvs_repository)
    set(STATUS_COMMAND ${CVS_EXECUTABLE} status)
    set(RESET_COMMAND)
  elseif(svn_repository)
    set(STATUS_COMMAND ${Subversion_SVN_EXECUTABLE} st -q)
    set(RESET_COMMAND ${Subversion_SVN_EXECUTABLE} revert -R .)
  elseif(git_repository)
    set(STATUS_COMMAND ${GIT_EXECUTABLE} status --untracked-files=no -s)
    set(RESET_COMMAND ${GIT_EXECUTABLE} reset -q HEAD -- COMMAND ${GIT_EXECUTABLE} checkout -- . COMMAND ${GIT_EXECUTABLE} clean -qdxf)
  endif()

  add_custom_target(${name}-stat
    COMMAND ${STATUS_COMMAND}
    COMMENT "${name} Status:"
    WORKING_DIRECTORY "${${NAME}_SOURCE}"
    )
  set_target_properties(${name}-stat PROPERTIES EXCLUDE_FROM_ALL ON)

  add_custom_target(${name}-reset
    COMMAND ${RESET_COMMAND}
    COMMENT "SCM reset on ${name}"
    WORKING_DIRECTORY "${${NAME}_SOURCE}"
    DEPENDS ${name}-download
    )
  add_custom_target(${name}-resetall DEPENDS ${name}-reset)
  set_target_properties(${name}-reset PROPERTIES EXCLUDE_FROM_ALL ON)
  set_target_properties(${name}-resetall PROPERTIES EXCLUDE_FROM_ALL ON)

  foreach(_dep ${${NAME}_DEPENDS})
    get_target_property(_dep_check ${_dep} _EP_IS_EXTERNAL_PROJECT)
    if(_dep_check EQUAL 1)
      add_dependencies(${name}-resetall ${_dep}-resetall)
    endif()
  endforeach()

  add_custom_target(${name}-deps
    DEPENDS ${DEPENDS}
    COMMENT "Building ${name} dependencies"
    )
  set_target_properties(${name}-deps PROPERTIES EXCLUDE_FROM_ALL ON)

  # disable tests if requested
  if(${${NAME}_NOTEST})
    set(${NAME}_NOTESTONLY ON)
  endif()

  # make optional if requested
  if(${${NAME}_OPTIONAL})
    set_target_properties(${name} PROPERTIES EXCLUDE_FROM_ALL ON)
    foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
      set_target_properties(${name}-${subtarget} PROPERTIES EXCLUDE_FROM_ALL ON)
    endforeach()
    add_dependencies(stats ${name}-stat)
  else()
    # add to meta sub-targets
    foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
      string(TOUPPER ${subtarget} UPPER_SUBTARGET)
      if(NOT ${NAME}_NO${UPPER_SUBTARGET})
        add_dependencies(${subtarget}s ${name}-${subtarget})
      endif()
    endforeach()
    add_dependencies(AllProjects ${name})
  endif()

  set_target_properties(${name} PROPERTIES FOLDER "00_Main")
  foreach(subtarget ${USE_EXTERNAL_SUBTARGETS})
    set_target_properties(${name}-${subtarget} PROPERTIES FOLDER ${name})
  endforeach()

  set_property(GLOBAL PROPERTY USE_EXTERNAL_${name} ON)
  set_property(GLOBAL PROPERTY USE_EXTERNAL_${name}_FOUND ON)
  set(BUILDING ${BUILDING} ${name} PARENT_SCOPE)

  if("${NAME}_ROOT_VAR" STREQUAL "")
    set(${NAME}_ROOT "${INSTALL_PATH}" PARENT_SCOPE)
  else()
    set(${${NAME}_ROOT_VAR} "${INSTALL_PATH}" PARENT_SCOPE)
  endif()
endfunction()
