package main

import (
	"context"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
)

const (
	defaultTSNetPort      = ":42424"
	defaultHostAddr       = "127.0.0.1:42425"
	defaultHostname       = "remotemac-embedded-probe"
	defaultMediaProbePort = "42428"
)

func envOrDefault(
	key string,
	fallback string,
) string {
	value := os.Getenv(key)

	if value == "" {
		return fallback
	}

	return value
}

func setupDebugLog() {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}

	path := os.Getenv(
		"REMOTEMAC_DEBUG_LOG",
	)

	if path == "" {
		path = filepath.Join(
			home,
			"Library",
			"Containers",
			"com.example.remotemac.MacHost",
			"Data",
			"Library",
			"Application Support",
			"RemoteMac",
			"transport-debug.log",
		)
	}

	if err := os.MkdirAll(
		filepath.Dir(path),
		0700,
	); err != nil {
		return
	}

	file, err := os.OpenFile(
		path,
		os.O_CREATE|os.O_WRONLY|os.O_APPEND,
		0600,
	)
	if err != nil {
		return
	}

	log.SetOutput(file)
	log.SetFlags(
		log.Ldate |
			log.Ltime |
			log.Lmicroseconds,
	)

	log.Printf(
		"TRANSPORT START pid=%d",
		os.Getpid(),
	)
}

func main() {
	setupDebugLog()
	// tsnet uses an in-process network stack and installs no OS tunnel routes.
	// Follow the Mac's routes instead of binding outer sockets to the physical
	// default interface, which bypasses full-device VPN routes and is blocked
	// by their kill switches. This matches tailscaled's userspace-networking mode.
	netns.SetEnabled(false)
	log.Printf("ROUTING using system routes (userspace transport)")
	stateDir := os.Getenv(
		"REMOTEMAC_TSNET_STATE_DIR",
	)

	if stateDir == "" {
		log.Fatal(
			"REMOTEMAC_TSNET_STATE_DIR is required",
		)
	}

	hostname := envOrDefault(
		"REMOTEMAC_TSNET_HOSTNAME",
		defaultHostname,
	)

	tsnetPort := envOrDefault(
		"REMOTEMAC_TSNET_LISTEN_ADDR",
		defaultTSNetPort,
	)

	hostAddr := envOrDefault(
		"REMOTEMAC_LOCAL_HOST_ADDR",
		defaultHostAddr,
	)

	log.Printf(
		"CONFIG hostname=%s listen=%s backend=%s",
		hostname,
		tsnetPort,
		hostAddr,
	)

	srv := &tsnet.Server{
		Hostname: hostname,
		Dir:      stateDir,
	}
	defer srv.Close()

	upTimeout := 60 * time.Second

	if value := os.Getenv(
		"REMOTEMAC_TSNET_UP_TIMEOUT",
	); value != "" {
		if parsed, err :=
			time.ParseDuration(value); err == nil {
			upTimeout = parsed
		}
	}

	log.Printf(
		"TSNET UP TIMEOUT %s",
		upTimeout,
	)

	ctx, cancel := context.WithTimeout(
		context.Background(),
		upTimeout,
	)
	defer cancel()

	if _, err := srv.Up(ctx); err != nil {
		log.Fatal(err)
	}

	ip4, ip6 := srv.TailscaleIPs()

	log.Println(
		"===== REMOTEMAC EMBEDDED TRANSPORT =====",
	)

	if ip4.IsValid() {
		log.Printf("IPv4: %s", ip4)
	}

	if ip6.IsValid() {
		log.Printf("IPv6: %s", ip6)
	}

	controlPeer := &mediaPeerState{}

	if ip4.IsValid() {
		mediaAddr := net.JoinHostPort(
			ip4.String(),
			defaultMediaProbePort,
		)

		media, err := srv.ListenPacket(
			"udp4",
			mediaAddr,
		)

		if err != nil {
			log.Printf(
				"UDP PROBE LISTEN FAILED addr=%s err=%v",
				mediaAddr,
				err,
			)
		} else {
			defer media.Close()

			log.Printf(
				"Tailnet UDP probe %s",
				mediaAddr,
			)

			mediaPeer :=
				&mediaPeerState{}

			go serveUDPProbe(
				media,
				mediaPeer,
				controlPeer,
			)

			localMedia, localErr :=
				net.ListenPacket(
					"udp4",
					"127.0.0.1:42429",
				)

			if localErr != nil {
				log.Printf(
					"LOCAL VIDEO LISTEN FAILED err=%v",
					localErr,
				)
			} else {
				defer localMedia.Close()

				log.Printf(
					"Local UDP video input 127.0.0.1:42429",
				)

				go forwardLocalMedia(
					localMedia,
					media,
					mediaPeer,
				)
			}
		}
	}

	ln, err := srv.Listen(
		"tcp",
		tsnetPort,
	)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()

	log.Printf(
		"Tailnet TCP %s -> %s",
		tsnetPort,
		hostAddr,
	)

	for {
		remote, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}

		controlPeer.set(
			remote.RemoteAddr(),
		)

		go bridge(remote, hostAddr)
	}
}

type mediaPeerState struct {
	mu   sync.RWMutex
	addr net.Addr
}

func (s *mediaPeerState) set(
	addr net.Addr,
) {
	s.mu.Lock()
	s.addr = addr
	s.mu.Unlock()
}

func (s *mediaPeerState) get() net.Addr {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.addr
}

func samePeerIP(
	a net.Addr,
	b net.Addr,
) bool {
	if a == nil || b == nil {
		return false
	}

	hostA, _, errA :=
		net.SplitHostPort(
			a.String(),
		)

	hostB, _, errB :=
		net.SplitHostPort(
			b.String(),
		)

	if errA != nil || errB != nil {
		return false
	}

	ipA := net.ParseIP(hostA)
	ipB := net.ParseIP(hostB)

	if ipA == nil || ipB == nil {
		return false
	}

	return ipA.Equal(ipB)
}

func serveUDPProbe(
	connection net.PacketConn,
	mediaPeer *mediaPeerState,
	controlPeer *mediaPeerState,
) {
	buffer := make(
		[]byte,
		2048,
	)

	for {
		n, remote, err :=
			connection.ReadFrom(
				buffer,
			)

		if err != nil {
			log.Printf(
				"UDP PROBE END err=%v",
				err,
			)

			return
		}

		if string(
			buffer[:n],
		) == "RMVIDEO1" {
			control :=
				controlPeer.get()

			if !samePeerIP(
				control,
				remote,
			) {
				log.Printf(
					"UDP VIDEO REGISTER REJECTED remote=%s control=%v",
					remote,
					control,
				)

				continue
			}

			mediaPeer.set(
				remote,
			)

			_, err =
				connection.WriteTo(
					[]byte(
						"RMVIDEOACK1",
					),
					remote,
				)

			if err != nil {
				log.Printf(
					"UDP VIDEO ACK FAILED remote=%s err=%v",
					remote,
					err,
				)

				continue
			}

			log.Printf(
				"UDP VIDEO PEER REGISTERED remote=%s",
				remote,
			)

			continue
		}

		if n < len("RMUDP1:") ||
			string(
				buffer[:len("RMUDP1:")],
			) != "RMUDP1:" {
			continue
		}

		_, err =
			connection.WriteTo(
				buffer[:n],
				remote,
			)

		if err != nil {
			log.Printf(
				"UDP PROBE WRITE FAILED remote=%s err=%v",
				remote,
				err,
			)

			continue
		}

		log.Printf(
			"UDP PROBE ECHO bytes=%d remote=%s",
			n,
			remote,
		)
	}
}

func forwardLocalMedia(
	local net.PacketConn,
	tailnet net.PacketConn,
	mediaPeer *mediaPeerState,
) {
	buffer := make(
		[]byte,
		2048,
	)

	var sent uint64
	var dropped uint64

	for {
		n, _, err :=
			local.ReadFrom(
				buffer,
			)

		if err != nil {
			log.Printf(
				"LOCAL VIDEO INPUT END err=%v",
				err,
			)

			return
		}

		peer :=
			mediaPeer.get()

		if peer == nil {
			dropped++

			if dropped%300 == 1 {
				log.Printf(
					"UDP VIDEO DROP no registered peer count=%d",
					dropped,
				)
			}

			continue
		}

		_, err =
			tailnet.WriteTo(
				buffer[:n],
				peer,
			)

		if err != nil {
			log.Printf(
				"UDP VIDEO SEND FAILED bytes=%d remote=%s err=%v",
				n,
				peer,
				err,
			)

			continue
		}

		sent++

		if sent%300 == 0 {
			log.Printf(
				"UDP VIDEO FORWARDED packets=%d remote=%s",
				sent,
				peer,
			)
		}
	}
}

func bridge(
	remote net.Conn,
	hostAddr string,
) {
	defer remote.Close()

	log.Printf(
		"BRIDGE OPEN remote=%s",
		remote.RemoteAddr(),
	)

	local, err := net.Dial(
		"tcp",
		hostAddr,
	)
	if err != nil {
		log.Printf(
			"BRIDGE LOCAL DIAL FAILED err=%v",
			err,
		)
		return
	}
	defer local.Close()

	log.Printf(
		"BRIDGE LOCAL CONNECTED remote=%s",
		remote.RemoteAddr(),
	)

	type copyResult struct {
		direction string
		bytes     int64
		err       error
	}

	done := make(
		chan copyResult,
		2,
	)

	go func() {
		n, err :=
			io.Copy(
				local,
				remote,
			)

		done <- copyResult{
			direction: "IPHONE_TO_HOST",
			bytes:     n,
			err:       err,
		}
	}()

	go func() {
		n, err :=
			io.Copy(
				remote,
				local,
			)

		done <- copyResult{
			direction: "HOST_TO_IPHONE",
			bytes:     n,
			err:       err,
		}
	}()

	first := <-done

	log.Printf(
		"BRIDGE FIRST END direction=%s bytes=%d err=%v",
		first.direction,
		first.bytes,
		first.err,
	)

	log.Printf(
		"BRIDGE CLOSING remote=%s",
		remote.RemoteAddr(),
	)
}
