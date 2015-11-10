cmake_minimum_required(VERSION 2.8)
if(NOT (${CMAKE_MAJOR_VERSION}.${CMAKE_MINOR_VERSION} LESS 3.0))
	# only CMAKE 3.0 and greater supports this (NOT ... LESS because CMAKE does not have a GREATER_OR_EQUAL_TO conditional)
	# Not needed for older versions because older versions obviously use the old policy without specially requesting it
	cmake_policy(SET CMP0048 OLD)
	# ^^^ use the old VERSION variable behavior
endif()
# Name this project
set(LSTORE_PROJECT_NAME "toolbox")
project(${LSTORE_PROJECT_NAME} C CXX)

# Include modules 
set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)
include(CheckIncludeFile)

# Detect compiler flags.
check_include_file("stdint.h" HAVE_STDINT_H)
check_include_file("inttypes.h" HAVE_INTTYPES_H)
configure_file(${CMAKE_SOURCE_DIR}/${LSTORE_PROJECT_NAME}_config.h.in
               ${CMAKE_SOURCE_DIR}/${LSTORE_PROJECT_NAME}_config.h)


# Find dependencies.
# common objects
set(NETWORK_OBJS 
    net_1_ssl.c net_2_ssl.c net_fd.c net_phoebus.c net_sock.c network.c
    phoebus.c 
)

set(TOOL_OBJS  
    append_printf.c apr_wrapper.c atomic_counter.c chksum.c dns_cache.c
    iniparse.c interval_skiplist.c log.c packer.c pigeon_coop.c pigeon_hole.c
    random.c skiplist.c stack.c string_token.c transfer_buffer.c varint.c
)

set(LSTORE_PROJECT_OBJS ${TOOL_OBJS} ${NETWORK_OBJS})
set(LSTORE_PROJECT_INCLUDES
                apr_wrapper.h debug.h list.h net_2_ssl.h fmttypes.h
                interval_skiplist.h net_1_ssl.h net_phoebus.h net_fd.h
                network.h pigeon_hole.h stack.h net_sock.h pigeon_coop.h
                skiplist.h toolbox_config.h phoebus.h random.h string_token.h
                type_malloc.h transfer_buffer.h packer.h append_printf.h
                chksum.h varint.h atomic_counter.h dns_cache.h iniparse.h
                log.h assert_result.h)
# TODO add adler header?
set(LSTORE_PROJECT_EXECUTABLES sl_test isl_test varint_test)


#set( CMAKE_VERBOSE_MAKEFILE on )

# enable or disable use of alternate performance optimized versions of some functions
# (may include use of architecture specific asm)
set(OPT_VERSIONS TRUE)

set(USE_ASM 0)   # TODO generalize this to scale to multiple platforms/arch/features
if(OPT_VERSIONS)
    if("${CMAKE_SYSTEM_PROCESSOR}" MATCHES "x86_64")
#        enable_language(ASM-ATT)
#        if(CMAKE_ASM-ATT_COMPILER_WORKS)
#                

#gcc -x assembler-with-cpp -c -o test.o adler32_x64.S

            add_custom_command(
                OUTPUT adler32_x64.o
                COMMAND gcc
                ARGS -x assembler-with-cpp -c -o adler32_x64.o ${CMAKE_SOURCE_DIR}/adler32_x64.S
                VERBATIM
            )
            set(USE_ASM 1)
            message(STATUS "OPT_VERSIONS is TRUE and conditions are met: Using alternate x86_64 optimized code where available.")

            set_source_files_properties(adler32_x64.o PROPERTIES GENERATED true)
            set(LSTORE_PROJECT_OBJS ${LSTORE_PROJECT_OBJS} adler32_x64.o) 
            configure_file(${CMAKE_SOURCE_DIR}/adler32_opt.h.in  ${CMAKE_SOURCE_DIR}/adler32_opt.h)
            set(LSTORE_PROJECT_INCLUDES ${LSTORE_PROJECT_INCLUDES} adler32_opt.h) 
#        endif(CMAKE_ASM-ATT_COMPILER_WORKS)
    endif("${CMAKE_SYSTEM_PROCESSOR}" MATCHES "x86_64")
endif(OPT_VERSIONS)

if(NOT USE_ASM)
    #
    message(STATUS "Not using alternate optimized code, either disabled (OPT_VERSIONS) or conditions not met.")
    configure_file(${CMAKE_SOURCE_DIR}/adler32_opt.h.in  ${CMAKE_SOURCE_DIR}/adler32_opt.h)
    set(LSTORE_PROJECT_INCLUDES ${LSTORE_PROJECT_INCLUDES} adler32_opt.h) 
endif(NOT USE_ASM)


# Common functionality is stored here
include(cmake/LStoreCommon.cmake)
