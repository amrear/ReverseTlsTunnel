import dns_resolve, hashes, print, parseopt, strutils, random, net, strutils, osproc , strformat
import std/sha1

export IpAddress

const version = "1"

type RunMode*{.pure.} = enum
    iran, kharej

var mode*: RunMode = RunMode.iran

# [Log Options]
const log_data_len* = false
const log_conn_create* = true
const log_conn_destory* = false
const log_conn_error* = true


# [Connection]
var trust_time*: uint = 3 #secs
var pool_size*: uint = 16
var max_idle_time*:uint = 240 #secs (default TCP RFC is 3600)
var max_pool_unused_time*:uint = 30 #secs 
const mux*: bool = false #asia tech firewall detects mux (connection max age rqeuired, TODO)
const socket_buffered* = false 
const chunk_size* = 8192

# [Routes]
const listen_addr* = "0.0.0.0"
var listen_port*:uint32 = 0
var next_route_addr* = ""
var next_route_port*:uint32 = 0
var iran_addr* = ""
var iran_port*:uint32 = 0

var final_target_domain* = ""
var final_target_ip*: string
const final_target_port* = 443 # port of the sni host (443 for tls handshake)
var self_ip*: IpAddress


# [passwords and hashes]
var password* = ""
var password_hash*: string
var sh1*: uint32
var sh2*: uint32
var sh3*: uint32
var sh4*: uint32
var sh5*: uint8
var random_600* = newString(len = 600)

# [settings]
var disable_ufw* = true
var reset_iptable* = true
var keep_system_limit* = false

# [multiport]
var multi_port* = false
var pmin:int
var pmax:int

# [posix constants]
const SO_ORIGINAL_DST* = 80
const SOL_IP* = 0

proc iptablesInstalled(): bool = 
    execCmdEx("""dpkg-query -W --showformat='${Status}\n' iptables|grep "install ok install"""").output != ""


proc resetIptables*()=
    echo "reseting iptable nat"
    assert 0 == execCmdEx("iptables -t nat -F").exitCode
    assert 0 == execCmdEx("iptables -t nat -X").exitCode

proc createIptablesRules*()=
    if reset_iptable:resetIptables()
    assert 0 == execCmdEx(&"""iptables -t nat -A PREROUTING -p tcp --dport {pmin}:{pmax} -j REDIRECT --to-port {listen_port}""").exitCode


proc init*() =
    print version

    for i in 0..<random_600.len():
        random_600[i] = rand(char.low .. char.high).char

    var p = initOptParser(longNoVal = @["kharej", "iran","multiport", "keep-ufw", "keep-iptables","keep-os-limit"])
    while true:
        p.next()
        case p.kind
        of cmdEnd: break
        of cmdShortOption, cmdLongOption:
            if p.val == "":
                case p.key:
                    of "kharej":
                        mode = RunMode.kharej
                        print mode
                    of "iran":
                        mode = RunMode.iran
                        print mode
                    of "keep-ufw":
                        disable_ufw = false
                    of "keep-iptables":
                        reset_iptable = false
                    of "multiport":
                        multiport = true
                    of "keep-os-limit":
                        keep_system_limit = true
                        
                    else:
                        echo "invalid option"
                        quit(-1)
            else:
                case p.key:
                    of "lport":
                        try:
                            listen_port = parseInt(p.val).uint32
                        except : #multi port
                            when defined(windows) or defined(android):
                                echo "multi listen port unsupported for windows."
                                quit(-1)
                            else:
                                if not iptablesInstalled():
                                    echo "multi listen port requires iptables to be installed."
                                    quit(-1)
                                multi_port = true
                                listen_port = 0 # will take a random port
                                pool_size = max(2.uint ,pool_size div 2.uint)
                                let port_range = p.val.split('-')
                                assert port_range.len == 2 , "Invalid listen port range. !"
                                pmin = max(1,port_range[0].parseInt)
                                pmax = min(65535,port_range[1].parseInt)
                                assert pmax-pmin >= 0, "port range is invalid!  use --lport:min-max"

                        print listen_port
                    of "toip":
                        next_route_addr = (p.val)
                        print next_route_addr
                    of "toport":
                        next_route_port = parseInt(p.val).uint32
                        print next_route_port

                    of "iran-ip":
                        iran_addr = (p.val)
                        print iran_addr
                    of "iran-port":
                        iran_port = parseInt(p.val).uint32
                        print iran_port

                    of "sni":
                        final_target_domain = (p.val)
                        print final_target_domain
                    of "password":
                        password = (p.val)
                        print password
                    of "pool":
                        pool_size = parseInt(p.val).uint
                        print pool_size
                    of "trust_time":
                        trust_time = parseInt(p.val).uint
                        print trust_time


        of cmdArgument:
            echo "Argument: ", p.key

    var exit = false

    case mode :
        of RunMode.kharej:
            if iran_addr.isEmptyOrWhitespace():
                echo "specify the ip address of the iran server --iran-addr:{ip}"
                exit = true
            if iran_port == 0 and not multi_port:
                echo "specify the iran server prot --iran-port:{port}"
                exit = true

            if next_route_addr.isEmptyOrWhitespace():
                echo "specify the next ip for routing --toip:{ip} (usually 127.0.0.1)"
                exit = true
            if next_route_port == 0:
                echo "specify the port of the next ip for routing --toport:{port} (the port of the config that x-ui shows you)"
                exit = true

        of RunMode.iran:
            if listen_port == 0 and not multi_port:
                echo "specify the listen prot --lport:{port}  (usually 443)"
                exit = true

   
    if final_target_domain.isEmptyOrWhitespace():
        echo "specify the sni for routing --sni:{domain}"
        exit = true
    if password.isEmptyOrWhitespace():
        echo "specify the password  --password:{something}"
        exit = true

    if exit: quit("Application did not start due to above logs.")

    
    final_target_ip = resolveIPv4(final_target_domain)
    print "\n"
    self_ip = getPrimaryIPAddr(dest = parseIpAddress("8.8.8.8"))
    password_hash = $(secureHash(password))
    sh1 = hash(password_hash).uint32
    sh2 = hash(sh1).uint32
    sh3 = hash(sh2).uint32
    sh4 = hash(sh3).uint32
    sh5 = (3 + (hash(sh2).uint32 mod 5)).uint8
    print password, password_hash, sh1, sh2, sh3, pool_size
    print "\n"
