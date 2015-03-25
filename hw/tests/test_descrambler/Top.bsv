// Copyright (c) 2015 Cornell University.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Vector::*;
import MemServer::*;
import MMU::*;
import Portal::*;
import HostInterface::*;
import CtrlMux::*;
import MemTypes::*;
import Leds::*;

// generated by tool
import DescramblerTestRequest::*;
import MemServerRequest::*;
import MMURequest::*;
import DescramblerTestIndication::*;
import MemServerIndication::*;
import MMUIndication::*;

import DescramblerTest::*;

typedef enum {DescramblerTestRequest, DescramblerTestIndication, HostMemServerIndication, HostMemServerRequest, HostMMURequest, HostMMUIndication} IfcNames deriving (Eq,Bits);

module mkConnectalTop(ConnectalTop#(PhysAddrWidth, DataBusWidth, Empty, 1));

   DescramblerTestIndicationProxy descramblerTestIndicationProxy <- mkDescramblerTestIndicationProxy(DescramblerTestIndication);
   DescramblerTest descramblerTest <- mkDescramblerTest(descramblerTestIndicationProxy.ifc);
   DescramblerTestRequestWrapper descramblerTestRequestWrapper <- mkDescramblerTestRequestWrapper(DescramblerTestRequest,descramblerTest.request);

   Vector#(1, MemReadClient#(128)) readClients = cons(descramblerTest.dmaClient, nil);
   MMUIndicationProxy hostMMUIndicationProxy <- mkMMUIndicationProxy(HostMMUIndication);
   MMU#(PhysAddrWidth) hostMMU <- mkMMU(0, True, hostMMUIndicationProxy.ifc);
   MMURequestWrapper hostMMURequestWrapper <- mkMMURequestWrapper(HostMMURequest, hostMMU.request);

   MemServerIndicationProxy hostMemServerIndicationProxy <- mkMemServerIndicationProxy(HostMemServerIndication);
   MemServer#(PhysAddrWidth,128,1) dma <- mkMemServerR(hostMemServerIndicationProxy.ifc, readClients, cons(hostMMU,nil));
   MemServerRequestWrapper hostMemServerRequestWrapper <- mkMemServerRequestWrapper(HostMemServerRequest, dma.request);

   Vector#(6,StdPortal) portals;
   portals[0] = hostMemServerIndicationProxy.portalIfc;
   portals[1] = hostMemServerRequestWrapper.portalIfc;
   portals[2] = hostMMURequestWrapper.portalIfc;
   portals[3] = hostMMUIndicationProxy.portalIfc;
   portals[4] = descramblerTestRequestWrapper.portalIfc;
   portals[5] = descramblerTestIndicationProxy.portalIfc;
   let ctrl_mux <- mkSlaveMux(portals);

   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = dma.masters;
   interface Empty pins; endinterface
endmodule : mkConnectalTop
