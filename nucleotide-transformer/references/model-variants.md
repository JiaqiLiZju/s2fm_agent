# Model Variants

Use this file when the user needs help choosing among `get_pretrained_model(...)` checkpoints.

## NT v1 models

These are the first-generation models:

- `500M_human_ref`
- `500M_1000G`
- `2B5_1000G`
- `2B5_multi_species`

Key properties grounded by the docs:

- encoder-only transformers
- learnable positional encodings
- 6 kbp context
- pretraining on either human reference, 1000 Genomes, or multispecies data

## NT v2 models

These are the optimized second-generation models:

- `50M_multi_species_v2`
- `100M_multi_species_v2`
- `250M_multi_species_v2`
- `500M_multi_species_v2`

Key properties grounded by the docs:

- rotary positional embeddings
- SwiGLU activations
- no biases and no dropout
- up to 2,048 tokens and about 12 kbp context
- multispecies pretraining

## Adjacent compatible variants (same API)

These are loaded through the same JAX entry point but are not the core NT v1/v2 set:

- `1B_agro_nt` (plant-focused AgroNT checkpoint)
- `codon_nt` (3-mer variant)

Compatibility note:

- Some environments also expose `50M_3mer_multi_species_v2` as a supported alias for the codon-style checkpoint.

## Selection guidance

- Choose v1 when the user explicitly names a v1 checkpoint or wants the exact original paper models.
- Choose v2 when the user wants the improved architecture or longer context.
- Choose `500M_human_ref` only when a human-reference-only model is specifically desired.
- Choose multispecies models when the user wants broader organism coverage.
- Choose `1B_agro_nt` when the user explicitly asks for plant-genome emphasis.
- Choose `codon_nt` (or alias `50M_3mer_multi_species_v2`) when the user explicitly wants the 3-mer family.
