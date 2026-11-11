cmake_minimum_required(VERSION 3.14)
project(desktop_backdrop_test LANGUAGES CXX)

add_executable(desktop_backdrop_test test.cpp)
target_compile_features(desktop_backdrop_test PRIVATE cxx_std_17)
target_compile_definitions(desktop_backdrop_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(desktop_backdrop_test PRIVATE /utf-8 /W4)
target_link_libraries(desktop_backdrop_test PRIVATE ole32 shell32 windowscodecs gdiplus)

enable_testing()
add_test(NAME desktop_backdrop_test COMMAND desktop_backdrop_test)
