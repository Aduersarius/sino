#pragma once
#include <stdint.h>
int pulse_smc_init(void);
void pulse_smc_shutdown(void);
/* Fills rpm[] and maxrpm[] (up to cap). Returns fan count, 0 on failure. */
int pulse_smc_fans(float *rpm, float *maxrpm, int cap);
int pulse_smc_temps(char *names32, float *celsius, int cap);
int pulse_pid_energy_nj(int pid, uint64_t *nanojoules);
int pulse_pid_footprint(int pid, uint64_t *bytes);
