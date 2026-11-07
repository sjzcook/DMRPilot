//
//  DMRPilot-Bridging-Header.h
//  DMRPilot
//
//  Swift 通过这个桥接头调用 C++ 写的协议核心：
//  和 C++ 写的协议核心：
//    Core/DMRCore.h    —— Homebrew（MMDVM / HBlink，62031）
//    Core/RewindCore.h —— BrandMeister 的 ODTP / Rewind（54006）
//    Core/YSFCore.h    —— YSF（System Fusion）反射器（42000 一类的端口）
//    Core/HRCore.h     —— AMBE+2 半速率声码器（Core/Vocoder/，DroidStar 原文件）
//  头文件本身都是纯 C（只有一条 extern "C" 声明块），所以不需要 .mm 中间层。
//

#import "Core/DMRCore.h"
#import "Core/RewindCore.h"
#import "Core/HRCore.h"
#import "Core/YSFCore.h"
