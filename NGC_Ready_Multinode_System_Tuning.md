**NGC.Ready Multi-node system tuning for NGC v2.3**

<table>
<thead>
<tr class="header">
<th><strong>Item</strong></th>
<th><strong>Description</strong></th>
</tr>
</thead>
<tbody>
<tr class="odd">
<td>ConnectX-6 Firmware version</td>
<td>20.29.2002</td>
</tr>
<tr class="even">
<td>ConnectX-6 Dx Firmware version</td>
<td>22.29.2002</td>
</tr>
<tr class="odd">
<td>BlueField-2 Firmware version</td>
<td>24.29.2002</td>
</tr>
<tr class="even">
<td>MLNX_OFED Version</td>
<td>MLNX_OFED_LINUX-5.2-2.2.0.0</td>
</tr>
<tr class="odd">
<td>Eth Switch ports</td>
<td><p>Set MTU to 9216</p>
<p>Enable PFC and ECN using the single “Do ROCE” command</p></td>
</tr>
<tr class="even">
<td>IB Switch OpenSM</td>
<td><p>Change IPoIB MTU to 4K:</p>
<p>[standalone: master] &gt; en</p>
<p>[standalone: master] # conf t</p>
<p>[standalone: master] (config) # ib partition Default mtu 4K force</p></td>
</tr>
<tr class="odd">
<td><strong>AMD CPUs: EPYC 7002 and 7003 series</strong></td>
<td></td>
</tr>
<tr class="even">
<td>BIOS Settings</td>
<td><p>CPU Power Management -&gt; Maximum Performance</p>
<p>Memory Frequency -&gt; Maximum Performance</p>
<p>Alg. Performance Boost Disable (ApbDis) -&gt; Enabled</p>
<p>ApbDis Fixed Socket P-State -&gt; P0</p>
<p>NUMA Nodes Per Socket -&gt; 2</p>
<p>L3 cache as NUMA Domain -&gt; Enabled</p>
<p>x2APIC Mode -&gt; Enabled</p>
<p>PCIe ACS -&gt; Disabled</p>
<p>Preferred IO -&gt; Disabled</p>
<p>Enhanced Preferred IO -&gt; Enabled</p></td>
</tr>
<tr class="odd">
<td>Boot grub settings</td>
<td>iommu=pt numa_balancing=disable processor.max_cstate=0</td>
</tr>
<tr class="even">
<td><strong>Intel CPUs: Xeon Gold and Platinum</strong></td>
<td></td>
</tr>
<tr class="odd">
<td>BIOS Settings</td>
<td>Out of the box</td>
</tr>
<tr class="even">
<td>Boot grub settings</td>
<td>intel_idle.max_cstate=0 processor.max_cstate=0 intel_pstate=disable</td>
</tr>
<tr class="odd">
<td>NIC PCIe settings</td>
<td><p>For each NIC PCIe function:</p>
<p>Change PCI MaxReadReq to 4096B</p>
<p>Run "setpci -s $PCI_FUNCTION 68.w", it will return 4 digits ABCD</p>
<p>--&gt; Run "setpci -s $PCI_FUNCTION 68.w=5BCD"</p></td>
</tr>
<tr class="even">
<td>Test Repository</td>
<td><a href="https://github.com/Mellanox/ngc_multinode_perf">https://github.com/Mellanox/ngc_multinode_perf</a></td>
</tr>
</tbody>
</table>
