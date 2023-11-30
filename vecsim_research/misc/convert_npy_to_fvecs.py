import numpy as np
import sys

def npy_to_fvecs(input_npy, output_fvecs):
    # Load the NumPy array from the .npy file
    data = np.load(input_npy)

    # Ensure the data is a 2D array (each row is a vector)
    if data.ndim != 2:
        raise ValueError("Input array must be 2D.")

    print("data.ndim: ", data.ndim)
    print("data.shape[0]: ", data.shape[0])
    print("data.shape[1]: ", data.shape[1])


    # Open the fvecs file in binary write mode
    with open(output_fvecs, 'wb') as f:
        # Write the number of vectors and dimensionality as 32-bit integers
        f.write(np.array([data.shape[0] * data.shape[1]], dtype=np.int32).tobytes())

        # Write each vector as a sequence of 32-bit floating-point numbers
        for vector in data:
            f.write(vector.astype(np.float32).tobytes())

if __name__ == "__main__":


	# Check if the correct number of command-line arguments is provided
    if len(sys.argv) != 3:
        print("Usage: python script.py input.npy output.fvecs")
        sys.exit(1)

    # Get input and output filenames from command-line arguments
    input_npy = sys.argv[1]
    output_fvecs = sys.argv[2]

    # Replace 'input.npy' and 'output.fvecs' with your input and output file paths
    #input_npy = '/root/redis/redis-scripts/vecsim_research/LAION_1M/text_emb_0.npy'
    #output_fvecs = '/root/redis/redis-scripts/vecsim_research/LAION_1M/text_emb_0.fvecs'

    npy_to_fvecs(input_npy, output_fvecs)




