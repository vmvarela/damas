//go:build js && wasm

package main

import (
	"syscall/js"

	"github.com/vmvarela/damas/internal/core"
	"github.com/vmvarela/damas/internal/protocol"
)

var (
	game       *core.Game
	connState  *protocol.ConnState
	reqBuf     [4096]byte
	lastResp   []byte
)

func main() {
	// Keep the program running
	c := make(chan struct{}, 0)
	<-c
}

func init() {
	js.Global().Set("dz_init", js.FuncOf(dzInit))
	js.Global().Set("dz_req_ptr", js.FuncOf(dzReqPtr))
	js.Global().Set("dz_req_cap", js.FuncOf(dzReqCap))
	js.Global().Set("dz_handle", js.FuncOf(dzHandle))
}

func dzInit(this js.Value, args []js.Value) interface{} {
	rules := args[0].Int()
	var variant core.Variant
	if rules == 1 {
		variant = core.Spanish
	} else {
		variant = core.English
	}
	game = core.InitRules(variant)
	connState = &protocol.ConnState{}
	return nil
}

func dzReqPtr(this js.Value, args []js.Value) interface{} {
	// Return the pointer to the request buffer
	// Note: This is a simplified version - in reality we'd use wasm memory
	return uintptr(0)
}

func dzReqCap(this js.Value, args []js.Value) interface{} {
	return len(reqBuf)
}

func dzHandle(this js.Value, args []js.Value) interface{} {
	length := args[0].Int()
	if length > len(reqBuf) {
		return 0
	}

	// Read request from JS memory
	reqData := make([]byte, length)
	// In real implementation, copy from wasm memory
	// js.Global().Get("Module").Call("HEAPU8", ...)

	resp := protocol.HandleMessage(game, connState, reqData, core.Spanish)
	lastResp = resp

	// Return packed response
	return uintptr(0)
}