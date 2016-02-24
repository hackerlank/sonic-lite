#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#include "SchedulerTopSimIndication.h"
#include "SchedulerTopSimRequest.h"
#include "GeneratedTypes.h"

#define RING_BUFFER_SIZE 16

static uint32_t server_index = 0;
static uint32_t rate = 0;
static uint64_t cycles = 0;
//static uint16_t num_of_servers_transmitting = 0;

static SchedulerTopSimRequestProxy *device = 0;

class SchedulerTopSimIndication : public SchedulerTopSimIndicationWrapper
{
public:
	virtual void display_time_slots_count(uint64_t num_of_time_slots_used) {
		fprintf(stderr, "TIME SLOTS = %lu\n", num_of_time_slots_used);
	}

	virtual void display_host_pkt_count(uint64_t num_of_host_pkt) {
		fprintf(stderr, "HOST PKT = %lu\n", num_of_host_pkt);
	}

	virtual void display_non_host_pkt_count(uint64_t num_of_non_host_pkt) {
		fprintf(stderr, "NON HOST PKT = %lu\n", num_of_non_host_pkt);
	}

	virtual void display_received_pkt_count(uint64_t num_of_received_pkt) {
		fprintf(stderr, "RECEIVED PKT = %lu\n", num_of_received_pkt);
	}

	virtual void display_rxWrite_pkt_count(uint64_t num_of_rxWrite_pkt) {
		fprintf(stderr, "PKT WRITTEN TO Rx = %lu\n", num_of_rxWrite_pkt);
	}

	virtual void display_dma_stats(uint64_t num_of_pkt_generated) {
	   fprintf(stderr, "Num of pkt generated by DMA = %lu\n",num_of_pkt_generated);
	}

	virtual void display_queue_0_stats(const bsvvector_Luint64_t_L16 queue0_stats){
		for (int i = 0; i < RING_BUFFER_SIZE; i = i + 1) {
			fprintf(stderr, "%ld ", queue0_stats[i]);
		}
		fprintf(stderr, "\n");
	}

	virtual void display_queue_1_stats(const bsvvector_Luint64_t_L16 queue1_stats){
		for (int i = 0; i < RING_BUFFER_SIZE; i = i + 1) {
			fprintf(stderr, "%ld ", queue1_stats[i]);
		}
		fprintf(stderr, "\n");
	}

	virtual void display_queue_2_stats(const bsvvector_Luint64_t_L16 queue2_stats){
		for (int i = 0; i < RING_BUFFER_SIZE; i = i + 1) {
			fprintf(stderr, "%ld ", queue2_stats[i]);
		}
		fprintf(stderr, "\n");
	}

	virtual void display_queue_3_stats(const bsvvector_Luint64_t_L16 queue3_stats){
		for (int i = 0; i < RING_BUFFER_SIZE; i = i + 1) {
			fprintf(stderr, "%ld ", queue3_stats[i]);
		}
		fprintf(stderr, "\n");
	}

	virtual void display_mac_send_count(uint64_t count) {
		fprintf(stderr, "MAC send = %lu\n", count);
	}

	virtual void display_sop_count_from_mac_rx(uint64_t count) {
	   fprintf(stderr, "sop = %lu\n", count);
	}

	virtual void display_eop_count_from_mac_rx(uint64_t count) {
	   fprintf(stderr, "eop = %lu\n", count);
	}

//	virtual void debug_dma(uint32_t dst_index) {
//		fprintf(stderr, "[DMA (%d)] Sending to dst index = %d\n", server_index,
//				                                                  dst_index);
//	}
//
//	virtual void debug_sched(uint8_t sop, uint8_t eop, uint64_t data_high,
//			                 uint64_t data_low) {
//		fprintf(stderr,"[SCHED (%d)] CONSUMING %d %d %016lx %016lx\n",server_index,
//				                      sop, eop, data_high, data_low);
//	}
//
//	virtual void debug_mac_tx(uint8_t sop, uint8_t eop, uint64_t data) {
//		fprintf(stderr,"[MAC (%d)] SENDING %d %d %016lx\n", server_index,
//				                                            sop, eop, data);
//	}
//
//	virtual void debug_mac_rx(uint8_t sop, uint8_t eop, uint64_t data) {
//		fprintf(stderr,"[MAC (%d)] RECEIVED %d %d %016lx\n", server_index,
//				                                            sop, eop, data);
//	}
//
    SchedulerTopSimIndication(unsigned int id) : SchedulerTopSimIndicationWrapper(id) {}
};

void configure_scheduler(SchedulerTopSimRequestProxy* device) {
	device->start_scheduler_and_dma(server_index,
									rate,
									cycles);
    device->debug();
}

int main(int argc, char **argv)
{
    SchedulerTopSimIndication echoIndication(IfcNames_SchedulerTopSimIndicationH2S);
    device = new SchedulerTopSimRequestProxy(IfcNames_SchedulerTopSimRequestS2H);

    if (argc != 4) {
        printf("Wrong number of arguments\n");
        exit(0);
    } else {
        server_index = atoi(argv[1]);
        rate = atoi(argv[2]);
        cycles = atol(argv[3]);
//		num_of_servers_transmitting = atoi(argv[4]);
    }

	sleep(server_index);
	configure_scheduler(device);

    while(1);
    return 0;
}
