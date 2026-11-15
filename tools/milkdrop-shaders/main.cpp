#include "GLSLGenerator.h"
#include "HLSLParser.h"
#include "HLSLTree.h"
#include <fstream>
#include <iostream>
#include <sstream>

// Usage: hlsl2glsl <file>   Reads assembled HLSL, writes GLSL to stdout, errors to stderr.
int main(int argc, char** argv) {
    if (argc < 2) return 2;
    std::ifstream in(argv[1]);
    std::stringstream ss; ss << in.rdbuf();
    std::string source = ss.str();
    M4::Allocator allocator;
    M4::HLSLTree tree(&allocator);
    M4::HLSLParser parser(&allocator, &tree);
    std::string pre;
    if (!parser.ApplyPreprocessor("", source.c_str(), source.size(), pre)) { std::cerr << "PREPROCESS FAILED\n"; return 3; }
    // The caller already put samplers and texsizes in; the preprocessed text is what's parsed.
    if (!parser.Parse("", pre.c_str(), pre.size())) { std::cerr << "PARSE FAILED\n"; return 4; }
    M4::GLSLGenerator generator;
    if (!generator.Generate(&tree, M4::GLSLGenerator::Target_FragmentShader, M4::GLSLGenerator::Version_330, "PS",
                            M4::GLSLGenerator::Options(M4::GLSLGenerator::Flag_AlternateNanPropagation))) {
        std::cerr << "GENERATE FAILED\n"; return 5;
    }
    std::cout << generator.GetResult();
    return 0;
}
