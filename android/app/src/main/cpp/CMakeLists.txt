cmake_minimum_required(VERSION 3.22.1)
project("avm_jni" LANGUAGES C)

add_library(avm_jni SHARED avm_jni.c)

add_library(avm SHARED IMPORTED)
set_target_properties(avm PROPERTIES IMPORTED_LOCATION
        ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libavm.so)

target_include_directories(avm_jni PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)
target_link_libraries(avm_jni avm ${log-lib})
