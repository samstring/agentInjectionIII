# Third-party notices

agentInjectionIII is designed to interoperate with and reuse ideas/runtime
components from John Holdsworth's InjectionNext / InjectionLite projects.

## InjectionNext

Repository: https://github.com/johnno1962/InjectionNext

MIT License

Copyright (c) 2024 John Holdsworth

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE.

## InjectionLite

Repository: https://github.com/johnno1962/InjectionLite

InjectionLite is also distributed under the MIT license. The build-log
recompilation strategy in `BuildLogCompiler.swift` is derived conceptually
from InjectionLite's `LogParser.swift` / `Recompiler.swift`; this repository
keeps the attribution above and intentionally implements only the headless
subset needed by agentInjectionIII.


## SwiftTrace

Repository: https://github.com/johnno1962/SwiftTrace

Copyright (c) 2015 John Holdsworth

SwiftTrace is distributed under an MIT-style license. agentInjectionIII does
not vendor SwiftTrace source code directly; the locally built InjectionNext
runtime contains it as an upstream dependency, and the DEBUG-only
`AgentTraceBridge` interacts with its Objective-C-visible tracing API and
`logOutput` callback.

The upstream license also notes incorporated/related code from
Oliver Letterer's `imp_implementationForwardingToSelector` project and
Facebook's `fishhook`; their source/header licensing remains applicable in
the upstream runtime.
