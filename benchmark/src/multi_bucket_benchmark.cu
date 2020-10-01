#include <iostream>
#include <algorithm>
#include <numeric>
#include <vector>
#include <thread>
#include <chrono>
#include "warpcore.cuh"
#include "../../ext/hpc_helpers/include/io_helpers.h"

template<class Key, class Value>
bool sufficient_memory(size_t size, float load, float headroom_factor = 1.1)
{
    const size_t capacity = size/load;
    const size_t key_val_bytes = sizeof(Key)+sizeof(Value);
    const size_t table_bytes = key_val_bytes*capacity;
    const size_t io_bytes = key_val_bytes*size;
    const size_t total_bytes = (table_bytes+io_bytes)*headroom_factor;

    size_t bytes_free, bytes_total;
    cudaMemGetInfo(&bytes_free, &bytes_total); CUERR

    return (total_bytes <= bytes_free);
}

uint64_t memory_partition(float factor = 0.4)
{
    size_t bytes_free, bytes_total;
    cudaMemGetInfo(&bytes_free, &bytes_total); CUERR

    return bytes_free * factor;
}

template<class T>
uint64_t num_unique(const std::vector<T>& v) noexcept
{
    T * keys_d = nullptr;
    cudaMalloc(&keys_d, sizeof(T) * v.size()); CUERR
    cudaMemcpy(keys_d, v.data(), sizeof(T) * v.size(), H2D); CUERR

    auto set = warpcore::HashSet<T>(v.size());

    set.insert(keys_d, v.size());

    cudaFree(keys_d);

    return set.size();
}

template<class HashTable>
HOSTQUALIFIER INLINEQUALIFIER
void multi_value_benchmark(
    const std::vector<typename HashTable::key_type>& keys,
    std::vector<uint64_t> input_sizes = {(1UL<<27)},
    std::vector<float> load_factors = {0.8},
    uint64_t dev_id = 0,
    bool print_headers = true,
    uint8_t iters = 5,
    std::chrono::milliseconds thermal_backoff = std::chrono::milliseconds(100))
{
    cudaSetDevice(dev_id); CUERR

    using index_t = typename HashTable::index_type;
    using key_t = typename HashTable::key_type;
    using value_t = typename HashTable::value_type;

    const auto max_input_size =
        *std::max_element(input_sizes.begin(), input_sizes.end());
    const auto min_load_factor =
        *std::min_element(load_factors.begin(), load_factors.end());

    if(max_input_size > keys.size())
    {
        std::cerr << "Maximum input size exceeded." << std::endl;
        exit(1);
    }

    if(!sufficient_memory<key_t, value_t>(max_input_size, min_load_factor))
    {
        std::cerr << "Not enough GPU memory." << std::endl;
        exit(1);
    }

    key_t* keys_d = nullptr;
    cudaMalloc(&keys_d, sizeof(key_t)*max_input_size); CUERR
    key_t* unique_keys_d = nullptr;
    cudaMalloc(&unique_keys_d, sizeof(key_t)*max_input_size); CUERR
    value_t* values_d = nullptr;
    cudaMalloc(&values_d, sizeof(value_t)*max_input_size); CUERR
    index_t * offsets_d = nullptr;
    cudaMalloc(&offsets_d, sizeof(index_t)*(max_input_size+1)); CUERR

    cudaMemcpy(keys_d, keys.data(), sizeof(key_t)*max_input_size, H2D); CUERR
    cudaMemset(values_d, 1, sizeof(value_t)*max_input_size); CUERR

    for(auto size : input_sizes)
    {
        for(auto load : load_factors)
        {
            // const std::uint64_t capacity = float(size) / load;
            // const std::uint64_t capacity = float(size) / HashTable::bucket_size() / load;
            const float factor =
                float(sizeof(key_t) + sizeof(value_t)) /
                     (sizeof(key_t) + sizeof(value_t)*HashTable::bucket_size());

            const std::uint64_t capacity = size * factor / load;

            HashTable hash_table(capacity);

            std::vector<float> insert_times(iters);
            for(uint64_t i = 0; i < iters; i++)
            {
                hash_table.init();
                cudaEvent_t insert_start, insert_stop;
                float t;
                cudaEventCreate(&insert_start);
                cudaEventCreate(&insert_stop);
                cudaEventRecord(insert_start, 0);
                hash_table.insert(keys_d, values_d, size);
                cudaEventRecord(insert_stop, 0);
                cudaEventSynchronize(insert_stop);
                cudaEventElapsedTime(&t, insert_start, insert_stop);
                cudaDeviceSynchronize(); CUERR
                insert_times[i] = t;
                std::this_thread::sleep_for (thermal_backoff);
            }
            const float insert_time =
                *std::min_element(insert_times.begin(), insert_times.end());

            // std::cerr << "keys in table: " << hash_table.num_keys() << '\n';

            // auto key_set = hash_table.get_key_set();
            // std::cerr << "keys in set: " << key_set.size() << '\n';

            index_t key_size_out = 0;
            index_t value_size_out = 0;

            hash_table.retrieve_all_keys(unique_keys_d, key_size_out); CUERR

            std::vector<float> query_times(iters);
            for(uint64_t i = 0; i < iters; i++)
            {
                cudaEvent_t query_start, query_stop;
                float t;
                cudaEventCreate(&query_start);
                cudaEventCreate(&query_stop);
                cudaEventRecord(query_start, 0);
                hash_table.retrieve(
                    unique_keys_d,
                    key_size_out,
                    offsets_d,
                    offsets_d+1,
                    values_d,
                    value_size_out);
                cudaEventRecord(query_stop, 0);
                cudaEventSynchronize(query_stop);
                cudaEventElapsedTime(&t, query_start, query_stop);
                cudaDeviceSynchronize(); CUERR
                query_times[i] = t;
                std::this_thread::sleep_for(thermal_backoff);
            }
            const float query_time =
                *std::min_element(query_times.begin(), query_times.end());

            const uint64_t total_input_bytes = (sizeof(key_t) + sizeof(value_t))*size;
            uint64_t ips = size/(insert_time/1000);
            uint64_t qps = size/(query_time/1000);
            float itp = helpers::B2GB(total_input_bytes) / (insert_time/1000);
            float qtp = helpers::B2GB(total_input_bytes) / (query_time/1000);
            uint64_t key_capacity = hash_table.capacity();
            uint64_t value_capacity = hash_table.value_capacity();
            float key_load = hash_table.key_load_factor();
            float value_load = hash_table.value_load_factor();
            float density = hash_table.storage_density();
            float relative_density = hash_table.relative_storage_density();
            uint64_t table_bytes = hash_table.bytes_total();
            warpcore::Status status = hash_table.pop_status();

            if(print_headers)
            {
                const char d = ' ';

                std::cout << "N=" << size << std::fixed
                    << d << "key_capacity=" << key_capacity
                    << d << "value_capacity=" << value_capacity
                    << d << "bits_key=" << sizeof(key_t)*CHAR_BIT
                    << d << "bits_value=" << sizeof(value_t)*CHAR_BIT
                    << d << "mb_keys=" << uint64_t(helpers::B2MB(sizeof(key_t)*size))
                    << d << "mb_values=" << uint64_t(helpers::B2MB(sizeof(value_t)*size))
                    << d << "key_load=" << key_load
                    << d << "value_load=" << value_load
                    << d << "density=" << density
                    << d << "relative_density=" << relative_density
                    << d << "table_bytes=" << table_bytes
                    << d << "insert_ms=" << insert_time
                    << d << "query_ms=" << query_time
                    << d << "IPS=" << ips
                    << d << "QPS=" << qps
                    << d << "insert_GB/s=" << itp
                    << d << "query_GB/s=" << qtp
                    << d << "status=" << status << std::endl;
            }
            else
            {
                const char d = ' ';

                std::cout << std::fixed
                    << size
                    << d << capacity
                    << d << sizeof(key_t)*CHAR_BIT
                    << d << sizeof(value_t)*CHAR_BIT
                    << d << uint64_t(helpers::B2MB(sizeof(key_t)*size))
                    << d << uint64_t(helpers::B2MB(sizeof(value_t)*size))
                    << d << key_load
                    << d << value_load
                    << d << density
                    << d << relative_density
                    << d << table_bytes
                    << d << insert_time
                    << d << query_time
                    << d << ips
                    << d << qps
                    << d << itp
                    << d << qtp
                    << d << status << std::endl;
            }
        }
    }

    cudaFree(keys_d); CUERR
    cudaFree(values_d); CUERR
}

int main(int argc, char* argv[])
{
    using namespace warpcore;

    using key_t = std::uint32_t;
    using value_t = std::uint32_t;

    using mb1_hash_table_t = MultiBucketHashTable<
        key_t,
        value_t,
        defaults::empty_key<key_t>(),
        defaults::tombstone_key<key_t>(),
        defaults::empty_key<value_t>(),
        defaults::probing_scheme_t<key_t, 8>,
        storage::key_value::AoSStore<key_t, ArrayBucket<value_t,1>>>;

    using mb2_hash_table_t = MultiBucketHashTable<
        key_t,
        value_t,
        defaults::empty_key<key_t>(),
        defaults::tombstone_key<key_t>(),
        defaults::empty_key<value_t>(),
        defaults::probing_scheme_t<key_t, 8>,
        storage::key_value::AoSStore<key_t, ArrayBucket<value_t,2>>>;

    using mb4_hash_table_t = MultiBucketHashTable<
        key_t,
        value_t,
        defaults::empty_key<key_t>(),
        defaults::tombstone_key<key_t>(),
        defaults::empty_key<value_t>(),
        defaults::probing_scheme_t<key_t, 8>,
        storage::key_value::AoSStore<key_t, ArrayBucket<value_t,4>>>;

    using mb8_hash_table_t = MultiBucketHashTable<
        key_t,
        value_t,
        defaults::empty_key<key_t>(),
        defaults::tombstone_key<key_t>(),
        defaults::empty_key<value_t>(),
        defaults::probing_scheme_t<key_t, 8>,
        storage::key_value::AoSStore<key_t, ArrayBucket<value_t,8>>>;

    const uint64_t max_keys = 1UL << 27;
    uint64_t dev_id = 0;
    std::vector<key_t> keys;

    if(argc > 2) dev_id = std::atoi(argv[2]);

    if(argc > 1)
    {
        keys = helpers::load_binary<key_t>(argv[1], max_keys);
    }
    else
    {
        keys.resize(max_keys);

        key_t * keys_d = nullptr;
        cudaMalloc(&keys_d, sizeof(key_t) * max_keys); CUERR

        helpers::lambda_kernel
        <<<SDIV(max_keys, 1024), 1024>>>
        ([=] DEVICEQUALIFIER
        {
            const uint64_t tid = blockDim.x * blockIdx.x + threadIdx.x;

            if(tid < max_keys)
            {
                keys_d[tid] = (tid % (max_keys / 8)) + 1;
            }
        });

        cudaMemcpy(keys.data(), keys_d, sizeof(key_t) * max_keys, D2H); CUERR

        cudaFree(keys_d); CUERR
    }

    multi_value_benchmark<mb1_hash_table_t>(
        keys,
        {max_keys},
        {0.8},
        dev_id);

    multi_value_benchmark<mb2_hash_table_t>(
        keys,
        {max_keys},
        {0.8},
        dev_id);

    multi_value_benchmark<mb4_hash_table_t>(
        keys,
        {max_keys},
        {0.8},
        dev_id);

    multi_value_benchmark<mb8_hash_table_t>(
        keys,
        {max_keys},
        {0.8},
        dev_id);
}
