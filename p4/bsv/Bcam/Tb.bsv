package Tb;

import GetPut::*;
import ClientServer::*;
import StmtFSM::*;
import FIFO::*;
import Pipe::*;

import PriorityEncoder2::*;
import Ram9b::*;
import BcamTypes::*;
import Bcam::*;

function Stmt testSeq(BinaryCam#(1024, 9) dut,
                      String dut_name);
    return seq
        noAction;
        action
            dut.writeServer.put(BcamWriteReq{addr:'h1, data:'h1});
        endaction
        delay(100);
        action
            dut.writeServer.put(BcamWriteReq{addr:'h1, data:'h2});
        endaction
        delay(100);
        action
            dut.writeServer.put(BcamWriteReq{addr:'h1, data:'h3});
        endaction
        delay(100);
        action
            dut.writeServer.put(BcamWriteReq{addr:'h1, data:'h2});
        endaction
        delay(100);
        action
            dut.readServer.request.put('h2);
        endaction
        delay(10);
        action
            let v <- dut.readServer.response.get;
            $display("read result=%x", fromMaybe(?,v));
        endaction
   endseq;
endfunction

(* synthesize *)
module mkTb (Empty);

   BinaryCam#(1024, 9) bcam <- mkBinaryCam_1024_9();
   //PEnc#(1024) pe <- mkPriorityEncoder();

   mkAutoFSM(testSeq(bcam, "bcam"));
   //mkAutoFSM(testSeq2(pe, "pe"));

endmodule: mkTb

endpackage: Tb
